// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /channels/{id}/messages/bulk-delete-by-author`: one author's recent
//! messages in a channel, selected by a time window rather than named ids.
//!
//! The gap this closes: `bulk_delete_messages` (`messages_bulk.rs`) only
//! takes an explicit id list, capped at [`MAX_BULK_DELETE_IDS`]. Selecting
//! sixty-four ids by hand while spam is still arriving is not the shape a
//! moderator actually reaches for during a raid - "this author's messages
//! from the last few minutes in this channel" is. This route answers that
//! shape and reuses everything downstream of resolving it to an id list:
//! this handler turns the window into ids and hands them straight to
//! [`Store::bulk_delete_messages`], the same validate-all-then-write
//! transaction, the same one-audit-row-per-author, and the same one
//! `Event::MessageDeleted` per message the id-list route publishes - see
//! that module's doc for why an aggregate event is not an option.
//!
//! Permission and reach are identical to the id-list route: `MANAGE_MESSAGES`
//! is the whole rule, and it reaches every message including an
//! administrator's, deliberately with no containment guard. See
//! `docs/decisions/0016-message-deletion-has-no-hierarchy.md`.
//!
//! **Why this needed its own migration.** `messages_channel_live(channel_id,
//! seq DESC)` and `messages_author(author_id)` each serve half of
//! `(author_id, channel_id, since)`; neither serves all three, so without an
//! index built for it this route would walk every live message the channel
//! has ever held to find one author's. Migration 0054 adds
//! `messages_author_channel_window(channel_id, author_id, created_at)`,
//! proved by `tests/messages_bulk_window_index_plan.rs`.
//!
//! **The cap.** [`MAX_BULK_DELETE_IDS`] bounds the match count the same way
//! it bounds the id-list route, reused rather than re-derived: the reasoning
//! (the op-stream resync gap) is the same regardless of how the ids were
//! chosen. `MAX_WINDOW_MINUTES` additionally bounds the request's own shape -
//! a raid is a matter of minutes, not days, and a window longer than that is
//! outside what this route is sized for. Exceeding either cap refuses the
//! whole request rather than truncating it, the same rule the id-list route
//! already keeps.

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
use super::messages_bulk::{MAX_BULK_DELETE_IDS, delete_and_publish};
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::now_ms;

/// Most minutes back a window may reach.
///
/// A day, not a politeness limit: a raid is acute, and the match-count cap
/// above already stops any single call from deleting more than
/// [`MAX_BULK_DELETE_IDS`] messages regardless of how far back the window
/// reaches. This exists so the request's own shape stays honest about what
/// it is for - a caller wanting to sweep further back than a day is asking
/// for retention or a different tool, not a raid response.
pub const MAX_WINDOW_MINUTES: u32 = 24 * 60;

#[derive(Deserialize)]
struct BulkDeleteWindowRequest {
    author_id: String,
    window_minutes: u32,
}

pub fn router() -> Router<AppState> {
    Router::new().route(
        "/channels/{channel_id}/messages/bulk-delete-by-author",
        post(bulk_delete_by_author),
    )
}

async fn bulk_delete_by_author(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<BulkDeleteWindowRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let author_id = UserId(parse_uuid(&req.author_id)?);

    if req.window_minutes == 0 || req.window_minutes > MAX_WINDOW_MINUTES {
        return Err(ApiError::BadRequest(
            "window_minutes must be between 1 and 1440",
        ));
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

    let since_ms = now_ms() - i64::from(req.window_minutes) * 60_000;
    let ids = state
        .store
        .message_ids_by_author_since(
            channel_id,
            author_id,
            since_ms,
            MAX_BULK_DELETE_IDS as i64 + 1,
        )
        .await?;

    if ids.len() > MAX_BULK_DELETE_IDS {
        return Err(ApiError::BadRequest(
            "too many messages match this window; narrow it and try again",
        ));
    }

    delete_and_publish(&state, channel_id, &ids, ctx.user_id, &[author_id]).await?;

    Ok(StatusCode::NO_CONTENT)
}
