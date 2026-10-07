// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /read-states`: the caller's own read marker in every channel they can
//! read, so a client signing in asks once instead of once per channel, and
//! `POST /read-states/read`, which reads a whole category or space in one go.

use axum::Router;
use axum::extract::State;
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json, WRITE};
use super::message_validation::parse_uuid;
use super::sync::{ReadStateDto, read_state_for};
use crate::ids::ChannelId;
use crate::permissions::Permissions;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/read-states", get(list_read_states))
        .route("/read-states/read", post(mark_channels_read))
}

/// Past this a client is marking more than any space lists, so it is a bug.
const MAX_CHANNELS_PER_MARK: usize = 200;

#[derive(Deserialize)]
struct MarkChannelsReadRequest {
    channel_ids: Vec<String>,
}

/// Reads each listed channel up to its newest message and announces it, so
/// every other device clears the badge. A channel the caller cannot view is
/// skipped rather than refused, as `/sync` does, so the answer never reveals
/// a hidden channel.
async fn mark_channels_read(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    State(state): State<AppState>,
    Json(req): Json<MarkChannelsReadRequest>,
) -> Result<Json<Vec<ChannelReadStateDto>>, ApiError> {
    if req.channel_ids.len() > MAX_CHANNELS_PER_MARK {
        return Err(ApiError::BadRequest("too many channels"));
    }
    let mut ids = Vec::with_capacity(req.channel_ids.len());
    for raw in &req.channel_ids {
        let id = ChannelId(parse_uuid(raw)?);
        if !ids.contains(&id) {
            ids.push(id);
        }
    }
    let granted = state
        .store
        .permissions_in_channels(ctx.user_id, &ids)
        .await?;
    let mut answers = Vec::new();
    for id in ids {
        let may_view = granted
            .get(&id)
            .is_some_and(|p| p.contains(Permissions::VIEW_CHANNEL));
        if !may_view {
            continue;
        }
        // The store clamps to the channel's newest seq, so MAX means "everything".
        super::read_sync::advance_and_announce(&state, ctx.user_id, id, i64::MAX).await?;
        answers.push(ChannelReadStateDto {
            channel_id: id.to_string(),
            state: read_state_for(&state, ctx.user_id, id).await?,
        });
    }
    Ok(Json(answers))
}

#[derive(Serialize)]
struct ChannelReadStateDto {
    channel_id: String,
    #[serde(flatten)]
    state: ReadStateDto,
}

/// Answers for exactly the channels `GET /channels` and `GET /dms` would
/// list, plus DMs the caller hid, because the per-channel route answers those
/// too. Nobody else's marker is ever read: the store query is keyed on the
/// caller's id.
async fn list_read_states(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<ChannelReadStateDto>>, ApiError> {
    let mut readable: Vec<ChannelId> = state
        .store
        .visible_channels(ctx.user_id)
        .await?
        .into_iter()
        .map(|channel| channel.id)
        .collect();
    let dm_ids = state.store.dm_channel_ids_for_user(ctx.user_id).await?;
    let dm_permissions = state
        .store
        .permissions_in_channels(ctx.user_id, &dm_ids)
        .await?;
    readable.extend(dm_ids.into_iter().filter(|id| {
        dm_permissions
            .get(id)
            .is_some_and(|granted| granted.contains(Permissions::VIEW_CHANNEL))
    }));

    let states = state.store.read_states_for(ctx.user_id, &readable).await?;
    Ok(Json(
        states
            .into_iter()
            .map(|read| ChannelReadStateDto {
                channel_id: read.channel_id.to_string(),
                state: ReadStateDto {
                    last_read_seq: read.last_read_seq,
                    unread: read.unread,
                    manually_unread: read.manually_unread,
                },
            })
            .collect(),
    ))
}
