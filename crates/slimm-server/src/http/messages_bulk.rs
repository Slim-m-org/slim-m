// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /channels/{id}/messages/bulk-delete`: one moderation act over several
//! messages.
//!
//! Split from `messages.rs` rather than grown into it, the same reason
//! `canvas_ops_apply` sits beside `canvas_ops_write`: that file is already past
//! the point where another handler plus its request type reads as an aside.
//!
//! **`MANAGE_MESSAGES` is the whole of the rule, and it reaches every message in
//! the channel including an administrator's.** That is settled deliberately
//! rather than inherited: this route briefly carried a containment guard, of
//! the kind that stops a moderator acting on somebody whose permissions theirs
//! do not contain, and it was taken back out. See
//! `docs/decisions/0016-message-deletion-has-no-hierarchy.md`.
//!
//! The short version is that the single delete has never had such a rule -
//! `escalation_guard` guards role edits, member moderation and voice kicks, and
//! has never guarded a message - so a guard here would have made deleting
//! sixty-four messages refuse where deleting the same sixty-four one at a time
//! succeeds. A rule that is trivially sidestepped by doing the same thing more
//! slowly is not protection; it is a difference between two doors into the same
//! room.
//!
//! The cap is what actually bounds this, not the rate-limit class. `Class::Write`
//! is flat-cost and generous by design; what keeps one request from wrecking a
//! channel is [`MAX_BULK_DELETE_IDS`], sized against the op stream rather than
//! against politeness - see its own doc.

use axum::Router;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::post;
use serde::Deserialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelId, MessageId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::BulkDeleteError;

/// Most ids one bulk delete may name.
///
/// Not a politeness limit. Every deleted message writes one op to the channel's
/// stream, and `OP_SNAPSHOT_GAP` is the point past which a client whose cursor
/// is behind is told to reset rather than catch up - which throws away that
/// channel's whole local cache. A cap three orders below it keeps any single
/// purge comfortably inside what a returning client can page through.
///
/// 64 is `MAX_REMOVE_IDS_PER_OP`'s number, taken deliberately: the canvas
/// already worked out that ids-in-a-frame arithmetic against the 4 KiB
/// WebSocket ceiling, and a second, differently-argued constant for the same
/// shape of problem would be a worse answer than reusing the one with its
/// reasoning written down.
pub const MAX_BULK_DELETE_IDS: usize = 64;

#[derive(Deserialize)]
struct BulkDeleteRequest {
    message_ids: Vec<String>,
}

pub fn router() -> Router<AppState> {
    Router::new().route(
        "/channels/{channel_id}/messages/bulk-delete",
        post(bulk_delete),
    )
}

async fn bulk_delete(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<BulkDeleteRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);

    if req.message_ids.is_empty() {
        return Err(ApiError::BadRequest("no message ids given"));
    }
    if req.message_ids.len() > MAX_BULK_DELETE_IDS {
        return Err(ApiError::BadRequest("too many message ids"));
    }

    // First, so this cannot say a channel exists; decision 0011's masking rule.
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::MANAGE_MESSAGES)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    let mut ids = Vec::with_capacity(req.message_ids.len());
    for raw in &req.message_ids {
        ids.push(MessageId(parse_uuid(raw)?));
    }

    let resolved = match state.store.message_authors_in(channel_id, &ids).await {
        Ok(found) => found,
        Err(BulkDeleteError::NotFound(_)) => {
            return Err(ApiError::NotFound("message not found"));
        }
        Err(BulkDeleteError::Internal(err)) => return Err(err.into()),
    };

    // The distinct authors, for the audit trail: one row each, not one per message.
    let mut subjects: Vec<UserId> = Vec::new();
    for (_, author_id) in &resolved {
        let Some(author_id) = author_id else { continue };
        if !subjects.contains(author_id) {
            subjects.push(*author_id);
        }
    }

    delete_and_publish(&state, channel_id, &ids, ctx.user_id, &subjects).await?;

    Ok(StatusCode::NO_CONTENT)
}

/// Deletes `ids` in one transaction, then fans the result out: one event per
/// message, the cascades, one reply-summary refresh, and the freed files.
pub(super) async fn delete_and_publish(
    state: &AppState,
    channel_id: ChannelId,
    ids: &[MessageId],
    actor_id: UserId,
    subjects: &[UserId],
) -> Result<(), ApiError> {
    let outcome = state
        .store
        .bulk_delete_messages(channel_id, ids, actor_id, subjects)
        .await?;

    // One event per message, each with its own seq; see this module's doc.
    for deleted in &outcome.deleted {
        state.hub.publish(Event::MessageDeleted {
            op_seq: Some(deleted.op_seq),
            channel_id,
            message_id: deleted.message_id,
        });
        // The DB trigger already dropped the pin row; tell live clients too.
        if deleted.was_pinned {
            state.hub.publish(Event::MessageUnpinned {
                channel_id,
                message_id: deleted.message_id,
            });
        }
    }
    super::message_forwards::publish_cascaded(state, outcome.cascade).await;
    // One reply-summary refresh for the whole batch; see `threads::notify_reply`.
    if !outcome.deleted.is_empty() {
        super::threads::notify_reply(state, channel_id).await;
    }
    for hex in &outcome.freed_attachments {
        if let Err(err) = state.media.delete_attachment(hex).await {
            tracing::warn!(%hex, error = %err, "failed to remove an orphaned attachment file");
        }
    }
    Ok(())
}
