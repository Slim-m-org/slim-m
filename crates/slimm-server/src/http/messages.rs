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
use axum::middleware::from_fn;
use axum::routing::{get, post};

use self::message_get::get_message;
use self::message_history::history;
use self::message_requests::{EditRequest, ListParams};
use self::message_send::send;
use super::AppState;
use super::embeds;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, Query, WRITE, enforce};
use super::module_hooks::{Draft, HookPoint, guard_write};
use super::post_commit::{after_commit, run_to_completion};
use crate::hub::{Event, MessageEvent};
use crate::ids::{ChannelId, MessageId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::Edited;

pub(crate) use self::message_dto::{AttachmentDto, MessageDto, ReactionDto};
pub(crate) use self::message_validation::parse_uuid;

pub(super) mod message_components;
pub(super) mod message_dto;
pub(super) mod message_enrich;
pub(super) mod message_forwards;
pub(super) mod message_get;
pub(super) mod message_history;
mod message_kind;
pub(super) mod message_mentions;
pub(super) mod message_requests;
mod message_send;
pub(super) mod message_validation;
pub(super) mod messages_bulk;
pub(super) mod messages_bulk_window;
pub(super) use self::message_validation::validate_content;

/// Message bodies carry one text field; cap it generously but bounded.
const MESSAGE_BODY_LIMIT: usize = 64 * 1024;
/// Default and maximum page sizes for history.
const DEFAULT_LIMIT: i64 = 50;
const MAX_LIMIT: i64 = 100;

/// The message routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/channels/{channel_id}/messages",
            get(list).merge(post(send).layer(from_fn(run_to_completion))),
        )
        .route(
            "/channels/{channel_id}/messages/{message_id}",
            get(get_message).merge(
                axum::routing::patch(edit)
                    .delete(delete)
                    .layer(from_fn(run_to_completion)),
            ),
        )
        .route(
            "/channels/{channel_id}/messages/{message_id}/history",
            get(history),
        )
        .layer(DefaultBodyLimit::max(MESSAGE_BODY_LIMIT))
}

// --- Handlers ---

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
    let messages = match (params.around, params.before) {
        (Some(_), Some(_)) => {
            return Err(ApiError::BadRequest(
                "`around` and `before` cannot be combined",
            ));
        }
        (Some(around), None) => {
            state
                .store
                .list_messages_around(channel_id, around, limit)
                .await?
        }
        (None, before) => state.store.list_messages(channel_id, before, limit).await?,
    };
    let dtos = self::message_enrich::with_reactions(&state, ctx.user_id, messages).await?;
    Ok(Json(dtos))
}

/// Soft-deletes a message. Deleting your own is allowed; deleting another's
/// needs MANAGE_MESSAGES, which is the one thing a moderator does to it.
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

    // Not being able to see the channel hides whether the message exists, exactly like edit.
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

    // Deleting your own message is allowed; deleting another's needs manage rights.
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
        self::message_forwards::publish_cascaded(&state, outcome.cascade).await;
        state.hub.publish(Event::Message(MessageEvent::Deleted {
            op_seq: outcome.op_seq,
            channel_id,
            message_id,
        }));
        // The DB trigger already dropped the pin row; tell live clients too.
        if outcome.was_pinned {
            state.hub.publish(Event::Message(MessageEvent::Unpinned {
                channel_id,
                message_id,
            }));
        }
        super::threads::notify_reply(&state, channel_id).await;
        // File reclamation only, best-effort; see the note on this function.
        for hex in outcome.freed_attachments {
            crate::blobs::release(&state.store, &state.media, &hex).await;
        }
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Mirrors `ForbiddenException.notAuthorCode` in the client.
const NOT_AUTHOR_CODE: &str = "not_author";

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
///
/// Nobody else edits it, moderators and administrators included: words shown
/// under someone's name are theirs, and a moderator removes a message instead.
async fn edit(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path((channel_id, message_id)): Path<(String, String)>,
    State(state): State<AppState>,
    Json(req): Json<EditRequest>,
) -> Result<Json<MessageDto>, ApiError> {
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

    if message.author_id != Some(ctx.user_id) {
        return Err(ApiError::Coded {
            status: StatusCode::FORBIDDEN,
            message: "only the author can edit a message",
            code: NOT_AUTHOR_CODE,
        });
    }
    super::write_refusal::require(&state, ctx.user_id, channel_id, Permissions::SEND_MESSAGES)
        .await?;
    self::message_kind::refuse_card_edit(&state, message_id, ctx.user_id).await?;

    // Read once and used three times: whether the note may be emptied, the live frame, and this response.
    let forwarded = state
        .store
        .forwards_for_messages(&[message_id])
        .await?
        .into_iter()
        .next()
        .map(|(_, summary)| summary);

    // An edit carries no attachment list, so nothing stands in for cleared text - unless the message forwards something.
    let content = &*validate_content(&req.content, forwarded.is_some())?;
    // Built before the text changes, so a refused embed leaves the edit undone rather than half done.
    let mut replacement = embeds::honored_for_edit(&state, ctx.user_id, req.embeds).await?;
    let draft = Draft {
        point: HookPoint::PreEdit,
        channel_id,
        actor: ctx.user_id,
        reply_to: message.reply_to_id,
        content: Some(content),
        carries_more: forwarded.is_some(),
        own_module: None,
    };
    let mut fields = replacement
        .as_mut()
        .map(|list| embeds::text_fields(list))
        .unwrap_or_default();
    let intercepted = guard_write(&state, &draft, &mut fields).await?;
    let content = intercepted.text(content);
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
            intercepted.save_annotations(&state, message.id).await;
            // Content changed, so the mention set may have too.
            after_commit(
                "its mentions",
                self::message_mentions::refresh_after_edit(
                    &state,
                    channel_id,
                    ctx.user_id,
                    &message,
                )
                .await,
            );

            state.hub.publish(Event::Message(MessageEvent::Edited {
                message: Arc::new(message.clone()),
                op_seq,
                forwarded: forwarded.clone().map(Arc::new),
                lookups: Default::default(),
            }));
            // A bare MessageEdited frame cannot shrink a client's cached runs (message_extras.dart), so this is the only signal that does.
            if code_runs_cleared {
                state
                    .hub
                    .publish(Event::Message(MessageEvent::CodeRunsCleared {
                        channel_id,
                        message_id: message.id,
                    }));
            }
            message
        }
    };
    let mut dto: MessageDto = updated.into();
    dto.forwarded = forwarded.map(Into::into);
    dto.link_previews_removed = state.store.link_previews_suppressed(message_id).await?;
    dto.embeds = embeds::after_edit(&state, channel_id, message_id, replacement).await?;
    Ok(Json(dto))
}
