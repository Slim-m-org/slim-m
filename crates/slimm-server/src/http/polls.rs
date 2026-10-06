// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Poll routes: create a message that carries a poll, and cast or change a
//! vote on one.
//!
//! A poll is not its own resource with its own creation endpoint: it is a
//! message, so creating one goes through the same idempotent-by-id, per-channel
//! `seq` allocation every other message send does (see
//! [`crate::store::Store::send_poll_message`]). Voting mirrors the reaction
//! routes closely: the same view-then-act permission gate, and a fan-out event
//! carrying the whole public tally rather than a delta so a client that missed
//! a frame cannot drift. Exactly like `ReactionsChanged`, the event never says
//! who voted for what; only the voter's own request response (and their own
//! later read) tells them their own choice.

use std::sync::Arc;

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{post, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::message_validation::validate_content;
use super::messages::{MessageDto, parse_uuid};
use crate::hub::Event;
use crate::ids::{ChannelId, MessageId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{CreatePollError, Poll as StorePoll, Store, VoteError, now_ms};

/// Poll bodies are small: a question, up to four short options, and an
/// optional close time.
const POLL_BODY_LIMIT: usize = 8 * 1024;

/// The poll routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/messages/polls", post(create))
        .route("/messages/{message_id}/polls/vote", put(vote))
        .layer(DefaultBodyLimit::max(POLL_BODY_LIMIT))
}

// --- Wire types ---

/// A poll, as rendered inline in a message: the question, its ordered options
/// with their public tallies, and this viewer's own pick.
///
/// `voted_option` is per-viewer, exactly like `ReactionDto::reacted`: it is
/// never broadcast, only ever returned to the caller who asked.
#[derive(Serialize)]
pub(crate) struct PollDto {
    question: String,
    options: Vec<PollOptionDto>,
    total_votes: i64,
    voted_option: Option<i64>,
    close_at: Option<i64>,
    /// Whether the server's own clock already considers this poll past
    /// `close_at`. Sent so a client never has to trust its own clock to
    /// decide whether voting is still allowed; the server refuses the write
    /// regardless of what this says.
    closed: bool,
}

#[derive(Serialize)]
struct PollOptionDto {
    position: i64,
    label: String,
    votes: i64,
}

impl From<StorePoll> for PollDto {
    fn from(poll: StorePoll) -> Self {
        let total_votes = poll.options.iter().map(|o| o.votes).sum();
        let closed = poll.close_at.is_some_and(|close_at| now_ms() >= close_at);
        Self {
            question: poll.question,
            options: poll
                .options
                .into_iter()
                .map(|o| PollOptionDto {
                    position: o.position,
                    label: o.label,
                    votes: o.votes,
                })
                .collect(),
            total_votes,
            voted_option: poll.voted_option,
            close_at: poll.close_at,
            closed,
        }
    }
}

/// Batch-attaches poll data to already-built message DTOs. Called from
/// [`super::message_enrich::with_reactions`] so every consumer of that shared
/// enrichment (list, search, sync, and the pinned-message list) renders a
/// poll inline without each needing its own call site or database round trip.
///
/// `ids` and `dtos` must be the same length and in the same order, which
/// holds because both are built from the same source list of messages in
/// [`super::message_enrich::with_reactions`].
///
/// Takes `&Store` rather than `&AppState`: nothing here reads any other field.
pub(crate) async fn attach_polls(
    store: &Store,
    viewer: UserId,
    ids: &[MessageId],
    dtos: &mut [MessageDto],
) -> anyhow::Result<()> {
    let polls = store.polls_for_messages(ids, viewer).await?;
    for (message_id, poll) in polls {
        if let Some(pos) = ids.iter().position(|id| *id == message_id) {
            dtos[pos].poll = Some(poll.into());
        }
    }
    Ok(())
}

fn refuse_hidden_poll_text(question: &str, options: &[String]) -> Result<(), ApiError> {
    use super::hidden_chars::is_hidden_char;
    if question.chars().any(is_hidden_char) {
        return Err(ApiError::BadRequest(
            "poll question must not contain control or invisible characters",
        ));
    }
    if options.iter().any(|o| o.chars().any(is_hidden_char)) {
        return Err(ApiError::BadRequest(
            "poll option must not contain control or invisible characters",
        ));
    }
    Ok(())
}

#[derive(Deserialize)]
struct CreatePollMessageRequest {
    /// Client-generated UUID (v7 preferred), exactly like an ordinary send;
    /// makes creation idempotent the same way.
    id: String,
    /// An optional caption riding alongside the poll. May be empty: the poll
    /// itself, not this field, is what a poll message is for.
    #[serde(default)]
    content: String,
    question: String,
    options: Vec<String>,
    /// Unix milliseconds. Omitted or null means the poll never closes.
    close_at: Option<i64>,
}

#[derive(Deserialize)]
struct VoteRequest {
    /// Which option, by its 0-based position.
    option: i64,
}

// --- Handlers ---

async fn create(
    Authed(ctx): Authed,
    Path(channel_id): Path<String>,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<CreatePollMessageRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);

    // Creating a poll is creating a message, so it is gated exactly like an
    // ordinary send: view plus send, evaluated in this channel specifically.
    let needed = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, needed)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    let content = validate_content(&req.content, true)?;
    refuse_hidden_poll_text(&req.question, &req.options)?;
    let id = MessageId(parse_uuid(&req.id)?);
    let sent = match state
        .store
        .send_poll_message(
            channel_id,
            ctx.user_id,
            id,
            content,
            &req.question,
            &req.options,
            req.close_at,
        )
        .await
    {
        Ok(sent) => sent,
        Err(CreatePollError::IdConflict) => {
            return Err(ApiError::Conflict("message id already used"));
        }
        Err(CreatePollError::InvalidQuestion) => {
            return Err(ApiError::BadRequest(
                "a poll question must not be empty and must fit the length limit",
            ));
        }
        Err(CreatePollError::InvalidOptionCount) => {
            return Err(ApiError::BadRequest("a poll needs between 2 and 4 options"));
        }
        Err(CreatePollError::InvalidOption) => {
            return Err(ApiError::BadRequest(
                "every poll option must be non-empty and fit the length limit",
            ));
        }
        Err(CreatePollError::Internal(e)) => return Err(e.into()),
    };

    let poll = state.store.poll_for_message(id, ctx.user_id).await?;
    let mut dto = MessageDto::from(sent.message.clone());
    // Fresh or a retry, the poll itself already exists by the time this reads
    // it, so both branches attach the same way.
    if let Some(poll) = poll.clone() {
        dto.poll = Some(poll.into());
    }

    if sent.fresh {
        // A poll's caption can carry a mention exactly like an ordinary message's content.
        super::message_mentions::resolve_and_store(
            &state,
            channel_id,
            ctx.user_id,
            sent.message.id,
            &sent.message.content,
        )
        .await?;

        // Nobody can have voted before this, the poll's own creation.
        let poll_for_event = poll.map(|mut poll| {
            poll.voted_option = None;
            poll
        });
        state.hub.publish(Event::MessageCreated {
            message: Arc::new(sent.message.clone()),
            // A poll message carries no attachment, and forwards nothing.
            attachments: Arc::new(Vec::new()),
            forwarded: None,
            app_surface: None,
            code_run: None,
            poll: poll_for_event.map(Arc::new),
            embeds: Arc::new(Vec::new()),
            call: None,
            components: std::sync::Arc::new(Vec::new()),
        });
        state.push.notify_message(
            state.store.clone(),
            crate::push::SentMessage {
                channel_id,
                author_id: ctx.user_id,
                message_id: sent.message.id,
                seq: sent.message.seq,
                content: sent.message.content.clone(),
                presence: state.hub.presence(),
            },
        );
    }

    Ok(Json(dto))
}

/// Resolves the message's channel and checks the caller may both see it and
/// send there, mirroring `reactions::authorize` exactly: viewing is checked
/// first so an unreadable message and a missing one answer identically,
/// rather than voting being usable to probe for one.
///
/// SEND_MESSAGES is evaluated in this channel specifically: holding it in some
/// other channel must not let a caller vote here.
async fn authorize(
    state: &AppState,
    user_id: UserId,
    message_id: MessageId,
) -> Result<ChannelId, ApiError> {
    let Some(message) = state.store.message(message_id).await? else {
        return Err(ApiError::NotFound("no such message"));
    };
    let permissions = state
        .store
        .permissions_in_channel(user_id, message.channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL) {
        return Err(ApiError::NotFound("no such message"));
    }
    // Voting costs the same permission sending does; see the note above.
    if !permissions.contains(Permissions::SEND_MESSAGES) {
        return Err(ApiError::Forbidden);
    }
    Ok(message.channel_id)
}

async fn vote(
    Authed(ctx): Authed,
    parts: Parts,
    Path(message_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<VoteRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let message_id = MessageId(parse_uuid(&message_id)?);
    let channel_id = authorize(&state, ctx.user_id, message_id).await?;

    let tally = match state
        .store
        .vote_poll(message_id, ctx.user_id, req.option)
        .await
    {
        Ok(tally) => tally,
        Err(VoteError::UnknownPoll) => return Err(ApiError::NotFound("no such poll")),
        Err(VoteError::PollClosed) => return Err(ApiError::Conflict("this poll is closed")),
        Err(VoteError::InvalidOption) => {
            return Err(ApiError::BadRequest("not a valid option for this poll"));
        }
        Err(VoteError::Internal(e)) => return Err(e.into()),
    };

    state.hub.publish(Event::PollVoted {
        channel_id,
        message_id,
        options: tally,
    });
    Ok(StatusCode::NO_CONTENT)
}
