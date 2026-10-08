// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Message HTTP routes: send, list, edit, and delete, each authorized
//! server-side through the permission evaluator. Full-text search lives in
//! [`super::search`], a separate module since it has its own validation and
//! error handling.
//!
//! Sends are idempotent by the client-supplied message id, so an at-least-once
//! client that retries never duplicates. Every handler checks permissions in the
//! target channel before touching the store: view to read, view plus send to
//! post, and authorship or manage-messages to edit or delete.

use std::sync::Arc;

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::get;
use serde::Deserialize;

use super::AppState;
use super::attachment_ids::parse_attachment_ids;
use super::channel_slow_mode::enforce_slow_mode;
use super::embeds;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, Query, enforce};
use super::message_components;
use super::message_get::get_message;
use super::message_history::history;
use super::post_commit::after_commit;
use crate::hub::Event;
use crate::ids::{ChannelId, MessageId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{Edited, NewMessage};

pub(crate) use super::message_dto::{AttachmentDto, MessageDto, ReactionDto};
pub(crate) use super::message_validation::parse_uuid;
pub(super) use super::message_validation::validate_content;

/// Message bodies carry one text field; cap it generously but bounded.
const MESSAGE_BODY_LIMIT: usize = 64 * 1024;
/// Default and maximum page sizes for history.
const DEFAULT_LIMIT: i64 = 50;
const MAX_LIMIT: i64 = 100;

/// The message routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/messages", get(list).post(send))
        .route(
            "/channels/{channel_id}/messages/{message_id}",
            get(get_message).patch(edit).delete(delete),
        )
        .route(
            "/channels/{channel_id}/messages/{message_id}/history",
            get(history),
        )
        .layer(DefaultBodyLimit::max(MESSAGE_BODY_LIMIT))
}

// --- Request bodies (the response DTO lives in `message_dto.rs`) ---

#[derive(Deserialize)]
struct SendRequest {
    /// Client-generated UUID (v7 preferred) that makes the send idempotent.
    id: String,
    content: String,
    /// Hex sha256 ids of attachments already uploaded through
    /// `POST /attachments`, in display order. Capped at
    /// [`MAX_ATTACHMENTS_PER_MESSAGE`]; referencing an id that was never
    /// uploaded (or was already swept as an orphan) is a 400, not a silent
    /// drop.
    #[serde(default)]
    attachment_ids: Vec<String>,
    /// The message this one replies to, if any. Must already exist in this
    /// same channel (live or soft-deleted); anything else is a 400.
    #[serde(default)]
    reply_to_id: Option<String>,
    /// The message this one forwards, if any. Unlike `reply_to_id` it may
    /// live in any channel the sender can see, and only its id is accepted:
    /// the server reads the original's author, timestamp and text for
    /// itself, so a request cannot dress its own text up as someone else's.
    /// `content` stays the sender's own note alongside the forward, and may
    /// be empty.
    #[serde(default)]
    forwarded_from_id: Option<String>,
    /// Structured content, honoured only from a bot; see [`send`].
    #[serde(default)]
    embeds: Vec<embeds::RawEmbed>,
    /// Buttons, honoured only from a bot; see decision 0039.
    #[serde(default)]
    components: Vec<crate::components::ComponentRow>,
}

#[derive(Deserialize)]
struct EditRequest {
    content: String,
}

#[derive(Deserialize)]
struct ListParams {
    before: Option<i64>,
    limit: Option<i64>,
}

// --- Handlers ---

/// Sends a message, idempotent by the client-generated message id.
///
/// A nonexistent channel grants no permissions, so this refuses both "you
/// cannot post here" and "no such channel" identically, revealing neither.
/// ATTACH_FILES is only demanded when the send actually carries something, so
/// an ordinary text message never needs it.
///
/// A retry of a send that already succeeded returns the stored message so the
/// client gets its acknowledgement, but must not repeat what already happened
/// once. Fanning it out again would show it twice to anyone whose client does
/// not de-duplicate, and pushing again would wake every idle recipient a
/// second time, outside the debounce window that exists to stop exactly that.
///
/// Push work is handed to a detached background task, because the message is
/// already committed and its response already on the way: a relay outage can
/// never turn a successful send into an error.
///
/// Unlike reactions and polls, attachments can exist the instant a message is
/// created (they were uploaded before this call and just linked inside it), so
/// the echoed response needs its own lookup rather than staying empty the way
/// a fresh message's reactions correctly do.
///
/// A fresh send is also where the channel's slow mode is enforced (see
/// `channel_slow_mode::enforce_slow_mode`), gated on the same `stored_already`
/// this function already computes for the forward check: a retry of a send
/// that already landed must never be refused for arriving "too soon".
/// `embeds` is honoured only from a bot, discarded otherwise.
async fn send(
    Authed(ctx): Authed,
    Path(channel_id): Path<String>,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<SendRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let attachment_ids = parse_attachment_ids(&req.attachment_ids)?;

    // ATTACH_FILES only when the send carries something; see this function's
    // note for why a missing channel and a denied one look the same.
    let mut needed = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    if !attachment_ids.is_empty() {
        needed = needed.union(Permissions::ATTACH_FILES);
    }
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, needed)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    // A forward with no note of its own is a complete message; so is one
    // that is only attachments.
    let carries_more = !attachment_ids.is_empty() || req.forwarded_from_id.is_some();
    let content = validate_content(&req.content, carries_more)?;
    let id = MessageId(parse_uuid(&req.id)?);
    let embeds = embeds::honored_for_send(&state, ctx.user_id, req.embeds).await?;
    let components =
        message_components::honored_for_send(&state, ctx.user_id, req.components).await?;
    let reply_to_id = req
        .reply_to_id
        .as_deref()
        .map(|raw| parse_uuid(raw).map(MessageId))
        .transpose()?;
    // A retry must not re-authorize what already succeeded; the authoritative check still runs in the transaction.
    let stored_already = state.store.message_including_deleted(id).await?.is_some();
    // Never on a retry: see `enforce_slow_mode`'s own doc for why a second attempt at an id that already landed must not be refused.
    let slow_mode_window_ms = match stored_already {
        true => None,
        false => enforce_slow_mode(&state, channel_id, ctx.user_id).await?,
    };
    let forward = match &req.forwarded_from_id {
        // Parsed even on a retry, so a malformed id is still a 400.
        Some(raw) => {
            let named = MessageId(parse_uuid(raw)?);
            match stored_already {
                true => None,
                false => Some(super::message_forwards::resolve(&state, ctx.user_id, named).await?),
            }
        }
        None => None,
    };
    let sent = state
        .store
        .send_message_with_slow_mode(
            NewMessage {
                channel_id,
                author_id: ctx.user_id,
                id,
                content,
                attachment_ids: &attachment_ids,
                reply_to_id,
                forward,
            },
            slow_mode_window_ms,
        )
        .await?;

    // Read once and used twice: the live frame and this response need the
    // same summaries, and a fresh message can already have them.
    let attachments: Vec<_> = state
        .store
        .attachments_for_messages(&[id])
        .await?
        .into_iter()
        .next()
        .map(|(_, summaries)| summaries)
        .unwrap_or_default();

    let forwarded = state
        .store
        .forwards_for_messages(&[id])
        .await?
        .into_iter()
        .next()
        .map(|(_, summary)| summary);

    let stored_embeds = after_commit(
        "its embeds",
        embeds::store_and_reload(&state, id, sent.fresh, &embeds).await,
    );
    let stored_components = after_commit(
        "its components",
        message_components::store_and_reload(&state, id, sent.fresh, &components).await,
    );

    // An idempotent retry must not fan out or push again; see this function's note.
    if sent.fresh {
        after_commit(
            "its mentions",
            super::message_mentions::resolve_and_store(
                &state,
                channel_id,
                ctx.user_id,
                sent.message.id,
                &sent.message.content,
            )
            .await,
        );
        super::read_sync::advance_for_author(&state, ctx.user_id, &sent.message).await;

        state.hub.publish(Event::MessageCreated {
            message: Arc::new(sent.message.clone()),
            attachments: Arc::new(attachments.clone()),
            forwarded: forwarded.clone().map(Arc::new),
            // An ordinary send never launches an app or carries a poll.
            app_surface: None,
            code_run: None,
            poll: None,
            embeds: Arc::new(stored_embeds.clone()),
            call: None,
            components: Arc::new(stored_components.clone()),
            lookups: Default::default(),
        });

        // Cheap in-memory decision only, real work detached; see this function's note.
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
        // A no-op for an ordinary channel; see `threads::notify_reply`.
        super::threads::notify_reply(&state, channel_id).await;
    }

    let mut dto: MessageDto = sent.message.into();
    dto.attachments = attachments.into_iter().map(AttachmentDto::from).collect();
    dto.forwarded = forwarded.map(Into::into);
    dto.embeds = embeds::dtos_from_stored(&state.link_previews, stored_embeds);
    dto.components = stored_components;
    Ok(Json(dto))
}

async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(channel_id): Path<String>,
    Query(params): Query<ListParams>,
    State(state): State<AppState>,
) -> Result<Json<Vec<MessageDto>>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    let limit = params.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let messages = state
        .store
        .list_messages(channel_id, params.before, limit)
        .await?;
    let dtos = super::message_enrich::with_reactions(&state, ctx.user_id, messages).await?;
    Ok(Json(dtos))
}

/// Soft-deletes a message. Deleting your own is allowed; deleting another's
/// needs MANAGE_MESSAGES, the same split as edit.
///
/// The row is fetched regardless of `deleted_at`, because a second delete must
/// succeed rather than 404, and telling "already gone" apart from "never
/// existed in this channel" is what makes that possible.
///
/// Freed attachment files are reclaimed best-effort and only logged on
/// failure. The database rows went in the same transaction as the soft delete
/// and the caller has already succeeded, so a leftover file is wasted disk,
/// not a correctness bug.
async fn delete(
    Authed(ctx): Authed,
    parts: Parts,
    Path((channel_id, message_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let message_id = MessageId(parse_uuid(&message_id)?);

    // Not being able to see the channel hides whether the message exists,
    // exactly like edit.
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    // Includes soft-deleted rows so a retry succeeds; see the note above.
    let message = state
        .store
        .message_including_deleted(message_id)
        .await?
        .filter(|m| m.channel_id == channel_id)
        .ok_or(ApiError::NotFound("message not found"))?;

    // Deleting your own message is allowed; deleting another's needs manage
    // rights, same split as edit.
    let is_author = message.author_id == Some(ctx.user_id);
    if !is_author
        && !state
            .store
            .has_permission(ctx.user_id, channel_id, Permissions::MANAGE_MESSAGES)
            .await?
    {
        return Err(ApiError::Forbidden);
    }

    let outcome = state.store.delete_message(message_id, ctx.user_id).await?;
    if outcome.deleted {
        super::message_forwards::publish_cascaded(&state, outcome.cascade).await;
        state.hub.publish(Event::MessageDeleted {
            op_seq: outcome.op_seq,
            channel_id,
            message_id,
        });
        // The DB trigger already dropped the pin row; tell live clients too.
        if outcome.was_pinned {
            state.hub.publish(Event::MessageUnpinned {
                channel_id,
                message_id,
            });
        }
        super::threads::notify_reply(&state, channel_id).await;
        // File reclamation only, best-effort; see the note on this function.
        for hex in outcome.freed_attachments {
            if let Err(err) = state.media.delete_attachment(&hex).await {
                tracing::warn!(error = %err, attachment = %hex, "failed to delete a freed attachment file");
            }
        }
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Edits a message. Rate-limited like the other writes in this module: an edit
/// re-runs the FTS5 re-index trigger, so leaving it uncapped let one account
/// churn the search index as fast as it could send requests.
///
/// Editing your own message needs SEND_MESSAGES, not merely authorship. An
/// edit republishes arbitrary new content to the whole channel, so without
/// that bit a member denied send - by an overwrite, or by being timed out -
/// keeps a complete substitute for sending, by rewriting anything they ever
/// posted. Deleting is left on authorship alone, because a delete publishes
/// an id rather than words.
async fn edit(
    Authed(ctx): Authed,
    parts: Parts,
    Path((channel_id, message_id)): Path<(String, String)>,
    State(state): State<AppState>,
    Json(req): Json<EditRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let message_id = MessageId(parse_uuid(&message_id)?);

    // Not being able to see the channel hides whether the message exists.
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    let message = state
        .store
        .message(message_id)
        .await?
        .filter(|m| m.channel_id == channel_id)
        .ok_or(ApiError::NotFound("message not found"))?;

    // Your own needs send rights, another's needs manage rights; see the note.
    let is_author = message.author_id == Some(ctx.user_id);
    let needed = if is_author {
        Permissions::SEND_MESSAGES
    } else {
        Permissions::MANAGE_MESSAGES
    };
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, needed)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    // Read once and used three times: whether the note may be emptied, the
    // live frame, and this response.
    let forwarded = state
        .store
        .forwards_for_messages(&[message_id])
        .await?
        .into_iter()
        .next()
        .map(|(_, summary)| summary);

    // An edit carries no attachment list, so nothing stands in for cleared text - unless the message forwards something.
    let content = validate_content(&req.content, forwarded.is_some())?;
    let updated = match state
        .store
        .edit_message(message_id, content, ctx.user_id)
        .await?
    {
        Edited::Gone => return Err(ApiError::NotFound("message not found")),
        // No op row was written, so nothing changed for anybody to be told about.
        Edited::Unchanged(message) => message,
        Edited::Edited {
            message,
            op_seq,
            code_runs_cleared,
        } => {
            // Content changed, so the mention set may have too; see resolve_and_store's own doc for the author-vs-editor choice below.
            super::message_mentions::resolve_and_store(
                &state,
                channel_id,
                message.author_id.unwrap_or(ctx.user_id),
                message.id,
                &message.content,
            )
            .await?;

            state.hub.publish(Event::MessageEdited {
                message: message.clone(),
                op_seq,
                forwarded: forwarded.clone(),
            });
            // A bare MessageEdited frame cannot shrink a client's cached runs (message_extras.dart), so this is the only signal that does.
            if code_runs_cleared {
                state.hub.publish(Event::CodeRunsCleared {
                    channel_id,
                    message_id: message.id,
                });
            }
            message
        }
    };
    let mut dto: MessageDto = updated.into();
    dto.forwarded = forwarded.map(Into::into);
    Ok(Json(dto))
}
