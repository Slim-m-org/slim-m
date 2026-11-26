// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One channel's read marker: `GET` and `PUT /channels/{id}/read` read it and
//! advance it, `PUT /channels/{id}/unread` marks the channel unread.

use axum::Router;
use axum::extract::{Path, State};
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json, WRITE};
use super::messages::parse_uuid;
use crate::ids::ChannelId;
use crate::permissions::Permissions;

/// The per-channel read routes, merged into [`super::sync::routes`] under its body limit.
pub(super) fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/read", get(get_read).put(put_read))
        .route("/channels/{channel_id}/unread", put(put_unread))
}

#[derive(Deserialize)]
struct MarkReadRequest {
    seq: i64,
}

#[derive(Serialize)]
pub(super) struct ReadStateDto {
    pub(super) last_read_seq: i64,
    pub(super) unread: i64,
    /// Whether the reader asked to see this channel as unread even though
    /// they have read it. Separate from `unread` because they are different
    /// facts: `unread` counts messages, this records an intention.
    pub(super) manually_unread: bool,
}

async fn get_read(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ReadStateDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    Ok(Json(read_state_for(&state, ctx.user_id, channel_id).await?))
}

async fn put_read(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<MarkReadRequest>,
) -> Result<Json<ReadStateDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    if req.seq < 0 {
        return Err(ApiError::BadRequest("seq must not be negative"));
    }
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    super::read_sync::advance_announce_and_push(&state, &ctx, channel_id, req.seq).await?;
    Ok(Json(read_state_for(&state, ctx.user_id, channel_id).await?))
}

/// Marks a channel unread: the note-to-self every comparable app offers.
///
/// A write rather than a read, and rate limited as one, because it stores an
/// intention. It deliberately does not move `last_read_seq`, which is
/// monotonic so that a late or out-of-order mark can never un-read a channel;
/// see [`crate::store::Store::mark_unread`].
async fn put_unread(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ReadStateDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    if let Some(last_read_seq) = state.store.mark_unread(ctx.user_id, channel_id).await? {
        state.hub.publish(crate::hub::Event::ReadStateChanged {
            user_id: ctx.user_id,
            channel_id,
            last_read_seq,
            manually_unread: true,
        });
    }
    Ok(Json(read_state_for(&state, ctx.user_id, channel_id).await?))
}

/// The three reads every read-state answer needs, in one place so the two
/// handlers that return one cannot drift apart.
pub(super) async fn read_state_for(
    state: &AppState,
    user_id: crate::ids::UserId,
    channel_id: ChannelId,
) -> Result<ReadStateDto, ApiError> {
    Ok(ReadStateDto {
        last_read_seq: state.store.last_read_seq(user_id, channel_id).await?,
        unread: state.store.unread_count(user_id, channel_id).await?,
        manually_unread: state.store.manually_unread(user_id, channel_id).await?,
    })
}
