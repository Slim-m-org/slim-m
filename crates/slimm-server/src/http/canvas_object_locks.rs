// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Locking a canvas object in place, and reading which are locked. See
//! migration `0101_canvas_object_locks.sql`; who may lock follows the same
//! own-object-or-`MANAGE_CANVAS` rule a move does.

use axum::Router;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::routing::{get, put};
use serde::Serialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{AuthedLimited, CANVAS, Json};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{CanvasObjectId, ChannelId, UserId};
use crate::permissions::Permissions;
use crate::store::LockError;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/canvas/object-locks", get(list))
        .route(
            "/channels/{channel_id}/canvas/objects/{object_id}/lock",
            put(lock).delete(unlock),
        )
}

#[derive(Serialize)]
struct LocksDto {
    object_ids: Vec<String>,
}

/// `GET /channels/{channel_id}/canvas/object-locks`.
async fn list(
    AuthedLimited(ctx): AuthedLimited<CANVAS>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<LocksDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    canvas_permissions(&state, ctx.user_id, channel_id).await?;
    let ids = state.store.list_canvas_object_locks(channel_id).await?;
    Ok(Json(LocksDto {
        object_ids: ids.into_iter().map(|id| id.to_string()).collect(),
    }))
}

/// `PUT .../canvas/objects/{object_id}/lock`.
async fn lock(
    AuthedLimited(ctx): AuthedLimited<CANVAS>,
    Path((channel_id, object_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    set(ctx.user_id, &state, &channel_id, &object_id, true).await
}

/// `DELETE .../canvas/objects/{object_id}/lock`.
async fn unlock(
    AuthedLimited(ctx): AuthedLimited<CANVAS>,
    Path((channel_id, object_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    set(ctx.user_id, &state, &channel_id, &object_id, false).await
}

async fn set(
    actor: UserId,
    state: &AppState,
    channel_id: &str,
    object_id: &str,
    locked: bool,
) -> Result<StatusCode, ApiError> {
    let channel_id = ChannelId(parse_uuid(channel_id)?);
    let object_id = CanvasObjectId(parse_uuid(object_id)?);
    let permissions = canvas_permissions(state, actor, channel_id).await?;
    if state.store.timed_out_until(actor).await?.is_some() {
        return Err(ApiError::Forbidden);
    }
    let may_moderate = permissions.contains(Permissions::MANAGE_CANVAS);
    let changed = match state
        .store
        .set_canvas_object_lock(channel_id, object_id, actor, may_moderate, locked)
        .await
    {
        Ok(changed) => changed,
        Err(LockError::NotFound) => {
            return Err(ApiError::NotFound("that id is not in this channel"));
        }
        Err(LockError::NotAuthorized) => return Err(ApiError::Forbidden),
        Err(LockError::Internal(err)) => return Err(err.into()),
    };
    // No await between the commit and this call; see `ws::permission_cache`.
    if changed {
        state.hub.publish(Event::CanvasObjectLockChanged {
            channel_id,
            object_id,
            locked,
        });
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn canvas_permissions(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
) -> Result<Permissions, ApiError> {
    let permissions = state
        .store
        .permissions_in_channel(user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS)) {
        return Err(ApiError::Forbidden);
    }
    Ok(permissions)
}
