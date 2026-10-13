// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reading and moving the shared slots a channel's canvas keeps for its
//! call participants' camera and screen-share tiles.
//!
//! A sibling of [`super::canvas`] rather than part of it, kept separate for
//! the same file-budget reason `canvas_write.rs` already is. See migration
//! `0040_canvas_media_slots.sql` for why a slot is its own table rather
//! than a `canvas_objects` row or a `canvas_ops` kind.
//!
//! Unlike moving a real canvas object, there is no own-object-versus-
//! `MANAGE_CANVAS` split here: a slot names the participant it represents,
//! not who arranged it, so anyone holding `VIEW_CHANNEL` and `USE_CANVAS`
//! may rearrange anyone's tile - the same shared-editing trust this
//! channel already grants over drawing.

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::extract::{Path, State};
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AuthedLimited, CANVAS, Json};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::ChannelId;
use crate::permissions::Permissions;
use crate::store::{CanvasMediaSlot, MediaSlotError, MediaSlotKind};

/// Every body here is a small JSON document; refused well before axum's 2 MB default.
const BODY_LIMIT: usize = 64 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/canvas/media-slots", get(list))
        .route(
            "/channels/{channel_id}/canvas/media-slots/{kind}/{user_id}",
            put(upsert),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
pub(crate) struct CanvasMediaSlotDto {
    kind: String,
    user_id: String,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    locked: bool,
    sent_to_back: bool,
    updated_at: i64,
}

impl From<CanvasMediaSlot> for CanvasMediaSlotDto {
    fn from(slot: CanvasMediaSlot) -> Self {
        Self {
            kind: slot.kind.as_str().to_owned(),
            user_id: slot.user_id.to_string(),
            x: slot.x,
            y: slot.y,
            w: slot.w,
            h: slot.h,
            locked: slot.locked,
            sent_to_back: slot.sent_to_back,
            updated_at: slot.updated_at,
        }
    }
}

#[derive(Serialize)]
struct SlotsDto {
    slots: Vec<CanvasMediaSlotDto>,
}

/// `GET /channels/{channel_id}/canvas/media-slots`.
async fn list(
    AuthedLimited(ctx): AuthedLimited<CANVAS>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<SlotsDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS)) {
        return Err(ApiError::Forbidden);
    }
    let slots = state.store.list_canvas_media_slots(channel_id).await?;
    Ok(Json(SlotsDto {
        slots: slots.into_iter().map(CanvasMediaSlotDto::from).collect(),
    }))
}

#[derive(Deserialize)]
struct UpsertParams {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    locked: bool,
    sent_to_back: bool,
}

/// `PUT /channels/{channel_id}/canvas/media-slots/{kind}/{user_id}`.
///
/// Idempotent in the sense a repeat with the same body changes nothing
/// further, but not keyed by a client id the way `placeCanvasObject` is:
/// every call names a real intended arrangement, so every successful call
/// publishes, including a retry after a lost response. Applying the same
/// state twice is a no-op for every receiver, which is the cheaper mistake
/// against the alternative of an idempotency table for a value that is
/// already a plain upsert.
async fn upsert(
    AuthedLimited(ctx): AuthedLimited<CANVAS>,
    Path((channel_id, kind, user_id)): Path<(String, String, String)>,
    State(state): State<AppState>,
    Json(params): Json<UpsertParams>,
) -> Result<Json<CanvasMediaSlotDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let user_id = crate::ids::UserId(parse_uuid(&user_id)?);
    let kind =
        MediaSlotKind::parse(&kind).ok_or(ApiError::BadRequest("unknown media slot kind"))?;

    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS)) {
        return Err(ApiError::Forbidden);
    }
    if state.store.timed_out_until(ctx.user_id).await?.is_some() {
        return Err(ApiError::Forbidden);
    }
    if state.store.user_profile(user_id).await?.is_none() {
        return Err(ApiError::NotFound("user not found"));
    }

    let slot = state
        .store
        .upsert_canvas_media_slot(
            channel_id,
            user_id,
            kind,
            (params.x, params.y, params.w, params.h),
            params.locked,
            params.sent_to_back,
        )
        .await;
    let slot = match slot {
        Ok(slot) => slot,
        Err(MediaSlotError::OutOfBounds) => {
            return Err(ApiError::BadRequest(
                "the tile is outside the world or too large",
            ));
        }
        Err(MediaSlotError::Locked) => return Err(ApiError::Forbidden),
        Err(MediaSlotError::Internal(err)) => return Err(err.into()),
    };

    // No await between the commit and this call; see `ws::permission_cache`.
    state.hub.publish(Event::CanvasMediaSlotChanged {
        channel_id,
        kind,
        user_id,
        x: slot.x,
        y: slot.y,
        w: slot.w,
        h: slot.h,
        locked: slot.locked,
        sent_to_back: slot.sent_to_back,
    });

    Ok(Json(CanvasMediaSlotDto::from(slot)))
}
