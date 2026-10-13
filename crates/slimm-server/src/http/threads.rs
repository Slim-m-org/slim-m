// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Opening the thread hanging off a message: `POST
//! .../messages/{message_id}/thread`. Gated on the same VIEW_CHANNEL plus
//! SEND_MESSAGES a plain send needs in the parent channel, because starting a
//! thread is a way of sending, not a way of managing the channel - see
//! docs/decisions/0005-threads.md for why a thread is a channel with a parent
//! rather than a container of its own kind.

use axum::Router;
use axum::extract::{Path, State};
use axum::http::request::Parts;
use axum::routing::{get, post};
use serde::Serialize;

use super::AppState;
use super::channels::ChannelDto;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::message_dto::AttachmentDto;
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelId, MessageId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{OpenThreadError, ThreadListItem};

/// The thread routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/channels/{channel_id}/messages/{message_id}/thread",
            post(open),
        )
        .route("/channels/{channel_id}/thread-parent", get(thread_parent))
        .route("/channels/{channel_id}/threads", get(list))
}

/// Opens (or reuses) the thread hanging off a message.
///
/// A nonexistent or unviewable channel answers identically, exactly like
/// `sendMessage`: this checks `VIEW_CHANNEL` and `SEND_MESSAGES` in the
/// parent channel and never asks the thread channel itself anything, since
/// it does not exist yet on the first call and inherits those bits from the
/// parent on every later one.
async fn open(
    Authed(ctx): Authed,
    parts: Parts,
    Path((channel_id, message_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<Json<ChannelDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let message_id = MessageId(parse_uuid(&message_id)?);

    let needed = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, needed)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    let thread = match state.store.open_thread(channel_id, message_id).await {
        Ok(thread) => thread,
        Err(OpenThreadError::UnknownMessage) => {
            return Err(ApiError::NotFound("message not found"));
        }
        Err(OpenThreadError::NestedThread) => {
            return Err(ApiError::BadRequest(
                "cannot open a thread on a message that is itself inside a thread",
            ));
        }
        Err(OpenThreadError::TooMany) => {
            return Err(ApiError::BadRequest(
                "this channel already has as many open threads as it can hold",
            ));
        }
        Err(OpenThreadError::Internal(e)) => return Err(e.into()),
    };
    // A race loser or a reopen of an existing thread sends nothing new; see `OpenedThread::fresh`.
    if thread.fresh {
        state.hub.publish(Event::ThreadUpdated {
            channel_id,
            parent_message_id: message_id,
            thread_channel_id: thread.channel.id,
            reply_count: 0,
            last_reply_at: None,
        });
    }
    Ok(Json(thread.channel.into()))
}

#[derive(Serialize)]
struct ThreadParentDto {
    parent_channel_id: Option<String>,
    parent_channel_name: Option<String>,
    parent_message_id: Option<String>,
    /// The parent message's current text. Null once [`Self::parent_deleted`]
    /// is true, since a soft-deleted row's content is never sent to a client
    /// through any other path either.
    parent_content: Option<String>,
    /// True once the parent message itself has been soft-deleted. A thread
    /// stays open (its replies are a separate channel) even after its parent
    /// is gone, so this is distinct from the whole-response masking above.
    parent_deleted: bool,
    /// Null once the parent's author account is anonymized, the same reason
    /// `Message::author_id` goes null.
    parent_author_id: Option<String>,
    parent_author_display_name: Option<String>,
    /// The parent message's attachments, so the thread panel shows what the
    /// thread is about; empty for a deleted parent.
    parent_attachments: Vec<AttachmentDto>,
}

impl ThreadParentDto {
    const NONE: Self = Self {
        parent_channel_id: None,
        parent_channel_name: None,
        parent_message_id: None,
        parent_content: None,
        parent_deleted: false,
        parent_author_id: None,
        parent_author_display_name: None,
        parent_attachments: Vec::new(),
    };
}

/// `GET /channels/{channel_id}/thread-parent`: what a cold-opened thread
/// panel needs to orient itself - a deep link, a reload, or a notification
/// never appears in `listChannels`/`listDirectMessages`, so it never learns
/// its own parent any other way.
///
/// The first three fields answer together, masked to all-null exactly the
/// way `getChannelPermissions` masks its own bitmask: whenever `channel_id`
/// does not exist, is not a thread, or the caller lacks VIEW_CHANNEL there
/// (already resolved through the thread-to-parent rule), so this cannot
/// become a second channel-existence oracle - see
/// docs/decisions/0011-per-channel-permissions.md for the precedent this
/// reuses rather than reinvents. The remaining fields describe the parent
/// message itself, resolved through [`Store::message`] the same way any
/// other read does, so a deleted parent answers `parent_deleted: true` with
/// no content rather than a stale copy or a second masked state.
async fn thread_parent(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ThreadParentDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL) {
        return Ok(Json(ThreadParentDto::NONE));
    }
    let Some(parent) = state.store.thread_parent(channel_id).await? else {
        return Ok(Json(ThreadParentDto::NONE));
    };
    let name = state
        .store
        .channel(parent.parent_channel_id)
        .await?
        .map(|c| c.name);
    let message = state.store.message(parent.parent_message_id).await?;
    let (parent_content, parent_deleted, parent_author_id, parent_author_display_name) =
        match message {
            Some(m) => (
                Some(m.content),
                false,
                m.author_id.map(|id| id.to_string()),
                m.author_display_name,
            ),
            // A channel's parent_message_id always names a real row, so a miss here means it was soft-deleted.
            None => (None, true, None, None),
        };
    let parent_attachments = if parent_deleted {
        Vec::new()
    } else {
        state
            .store
            .attachments_for_messages(&[parent.parent_message_id])
            .await?
            .into_iter()
            .flat_map(|(_, summaries)| summaries)
            .map(AttachmentDto::from)
            .collect()
    };
    Ok(Json(ThreadParentDto {
        parent_channel_id: Some(parent.parent_channel_id.to_string()),
        parent_channel_name: name,
        parent_message_id: Some(parent.parent_message_id.to_string()),
        parent_content,
        parent_deleted,
        parent_author_id,
        parent_author_display_name,
        parent_attachments,
    }))
}

/// One row of `GET /channels/{channel_id}/threads`.
#[derive(Serialize)]
struct ThreadListItemDto {
    id: String,
    parent_message_id: String,
    /// The parent message's current text - a snippet for the client to
    /// truncate for display, not a copy frozen at open time; see
    /// [`crate::store::ThreadListItem::parent_content`].
    parent_content: String,
    parent_author_id: Option<String>,
    parent_author_display_name: Option<String>,
    created_at: i64,
    reply_count: i64,
    last_reply_at: Option<i64>,
    /// How many of this thread's live messages the caller has not yet read.
    unread_count: i64,
}

impl From<ThreadListItem> for ThreadListItemDto {
    fn from(item: ThreadListItem) -> Self {
        Self {
            id: item.thread_channel_id.to_string(),
            parent_message_id: item.parent_message_id.to_string(),
            parent_content: item.parent_content,
            parent_author_id: item.parent_author_id.map(|id| id.to_string()),
            parent_author_display_name: item.parent_author_display_name,
            created_at: item.created_at,
            reply_count: item.reply_count,
            last_reply_at: item.last_reply_at,
            unread_count: item.unread_count,
        }
    }
}

/// `GET /channels/{channel_id}/threads`: every live thread hanging off a
/// message in this channel, newest activity first.
///
/// One check, on `channel_id` alone: a thread's own visibility always
/// resolves to its parent's (see this module's own doc comment), so a
/// caller who can view `channel_id` can see every thread it lists, and one
/// who cannot gets the same `403` `listMessages` would give them for the
/// same channel - never a filtered or masked answer, since there is nothing
/// left to filter once the one check has already refused.
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Vec<ThreadListItemDto>>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    let items = state.store.list_threads(channel_id, ctx.user_id).await?;
    Ok(Json(
        items.into_iter().map(ThreadListItemDto::from).collect(),
    ))
}

/// Publishes a `ThreadUpdated` frame when `channel_id` is a thread's own
/// channel, so a bystander watching the parent sees the reply count move
/// live. Called from the message send path; best-effort, since the send it
/// rides on has already succeeded and must not be failed by this lookup.
pub(super) async fn notify_reply(state: &AppState, channel_id: ChannelId) {
    let parent = match state.store.thread_parent(channel_id).await {
        Ok(parent) => parent,
        Err(err) => {
            tracing::warn!(error = %err, "failed to resolve a thread's parent for a live update");
            return;
        }
    };
    let Some(parent) = parent else { return };
    let summary = match state
        .store
        .thread_summaries_for_messages(&[parent.parent_message_id])
        .await
    {
        Ok(rows) => rows.into_iter().next(),
        Err(err) => {
            tracing::warn!(error = %err, "failed to resolve a thread's reply summary for a live update");
            return;
        }
    };
    let Some((_, summary)) = summary else { return };
    state.hub.publish(Event::ThreadUpdated {
        channel_id: parent.parent_channel_id,
        parent_message_id: parent.parent_message_id,
        thread_channel_id: channel_id,
        reply_count: summary.reply_count,
        last_reply_at: summary.last_reply_at,
    });
}
