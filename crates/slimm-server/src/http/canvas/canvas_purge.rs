// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting a canvas object, which is always for good (decision 0085): erased
//! first, so every viewer drops it, then its rows and image bytes are deleted.

use axum::extract::{Path, State};
use axum::routing::delete;
use axum::{Json, Router};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{AuthedLimited, CANVAS};
use super::super::messages::parse_uuid;
use super::CanvasObjectDto;
use super::canvas_ops_write::publish;
use crate::hub::Event;
use crate::ids::{CanvasObjectId, CanvasOpId, ChannelId};
use crate::permissions::Permissions;
use crate::store::{CanvasOpRequest, LockError, PurgeError, SubmitOpError};

pub fn routes() -> Router<AppState> {
    Router::new().route(
        "/channels/{channel_id}/canvas/objects/{object_id}",
        delete(purge),
    )
}

/// `DELETE /channels/{channel_id}/canvas/objects/{object_id}`: the author or a
/// canvas moderator deletes the object for good and gets its last row back.
async fn purge(
    AuthedLimited(ctx): AuthedLimited<CANVAS>,
    Path((channel_id, object_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<Json<CanvasObjectDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let object_id = CanvasObjectId(parse_uuid(&object_id)?);
    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    let needed = Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS);
    if !permissions.contains(needed) {
        return Err(ApiError::Forbidden);
    }
    let may_moderate = permissions.contains(Permissions::MANAGE_CANVAS);

    // A moderator's purge outranks a pin; an author must unlock their own object first.
    if may_moderate {
        match state
            .store
            .set_canvas_object_lock(channel_id, object_id, ctx.user_id, true, false)
            .await
        {
            Ok(Some(version)) => state.hub.publish(Event::CanvasObjectLockChanged {
                channel_id,
                object_id,
                locked: false,
                version,
            }),
            Ok(None) | Err(LockError::NotFound) => {}
            Err(LockError::NotAuthorized) => return Err(ApiError::Forbidden),
            Err(LockError::Internal(err)) => return Err(err.into()),
        }
    }

    let op_id = CanvasOpId::generate();
    let erased = state
        .store
        .submit_canvas_op(
            channel_id,
            ctx.user_id,
            op_id,
            may_moderate,
            CanvasOpRequest::Remove(vec![object_id]),
        )
        .await;
    match erased {
        Ok(outcome) if outcome.fresh && outcome.affected > 0 => {
            publish(&state, channel_id, op_id, &outcome);
        }
        Ok(_) => {}
        Err(SubmitOpError::NotFound) => {
            return Err(ApiError::NotFound("that id is not in this channel"));
        }
        Err(SubmitOpError::NotAuthorized) => return Err(ApiError::Forbidden),
        Err(SubmitOpError::Internal(err)) => return Err(err.into()),
        Err(_) => return Err(ApiError::Conflict("that object could not be erased")),
    }

    match state.store.purge_canvas_object(channel_id, object_id).await {
        Ok(object) => Ok(Json(CanvasObjectDto::from(object))),
        Err(PurgeError::NotFound) => Err(ApiError::NotFound("that id is not in this channel")),
        Err(PurgeError::StillLive) if !may_moderate => {
            Err(ApiError::Conflict("unlock that object before deleting it"))
        }
        Err(PurgeError::StillLive) => Err(ApiError::Conflict("that object came back; try again")),
        Err(PurgeError::Internal(err)) => Err(err.into()),
    }
}
