// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pinned message routes: pin, unpin, list, and a cheap count for the channel
//! header.
//!
//! Pinning is a moderation action, gated on MANAGE_MESSAGES like editing or
//! deleting someone else's message, evaluated per channel through the
//! permission evaluator rather than a deployment-wide check - a distinction
//! that mattered enough to be its own audit finding elsewhere in this
//! codebase, so it is deliberate here rather than assumed. Reading the pin
//! list or its count needs only VIEW_CHANNEL, the same as reading messages.

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, Query, enforce};
use super::message_enrich::with_reactions;
use super::messages::{MessageDto, parse_uuid};
use crate::hub::Event;
use crate::ids::{ChannelId, MessageId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{MAX_PINS_PER_CHANNEL, PinError, PinnedMessage};

/// A narrower page than the whole bounded set, for a caller that only wants
/// the newest few. The set itself is capped at the pin rather than here.
#[derive(Deserialize)]
struct ListParams {
    limit: Option<i64>,
}

/// Every body here is a small JSON document; refused well before axum's 2 MB default.
const BODY_LIMIT: usize = 64 * 1024;

/// The pin routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/channels/{channel_id}/messages/{message_id}/pin",
            put(pin).delete(unpin),
        )
        .route("/channels/{channel_id}/pins", get(list))
        .route("/channels/{channel_id}/pins/count", get(count))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

// --- Wire types ---

/// A pinned message: the full message, flattened, plus when and by whom it
/// was pinned. Flattened rather than nested so a client that already has a
/// `Message` model can decode this as one with two extra fields, instead of
/// needing a second wrapper type just for the pin list.
#[derive(Serialize)]
struct PinDto {
    #[serde(flatten)]
    message: MessageDto,
    pinned_at: i64,
    pinned_by: Option<String>,
}

impl From<PinnedMessage> for PinDto {
    fn from(pin: PinnedMessage) -> Self {
        Self {
            message: pin.message.into(),
            pinned_at: pin.pinned_at,
            pinned_by: pin.pinned_by.map(|id| id.to_string()),
        }
    }
}

#[derive(Serialize)]
struct PinCountDto {
    count: i64,
}

// --- Handlers ---

async fn pin(
    Authed(ctx): Authed,
    parts: Parts,
    Path((channel_id, message_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let message_id = MessageId(parse_uuid(&message_id)?);
    authorize_manage(&state, ctx.user_id, channel_id).await?;

    let pin = match state
        .store
        .pin_message(channel_id, message_id, ctx.user_id)
        .await
    {
        Ok(pin) => pin,
        Err(PinError::UnknownMessage) => return Err(ApiError::NotFound("message not found")),
        Err(PinError::TooMany) => {
            return Err(ApiError::BadRequest(
                "this channel already has as many pinned messages as it can hold",
            ));
        }
        Err(PinError::Internal(e)) => return Err(e.into()),
    };

    state.hub.publish(Event::MessagePinned {
        channel_id,
        message_id,
        pinned_by: pin.pinned_by,
        pinned_at: pin.pinned_at,
    });
    Ok(StatusCode::NO_CONTENT)
}

async fn unpin(
    Authed(ctx): Authed,
    parts: Parts,
    Path((channel_id, message_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let message_id = MessageId(parse_uuid(&message_id)?);
    authorize_manage(&state, ctx.user_id, channel_id).await?;

    state.store.unpin_message(channel_id, message_id).await?;
    state.hub.publish(Event::MessageUnpinned {
        channel_id,
        message_id,
    });
    Ok(StatusCode::NO_CONTENT)
}

async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(channel_id): Path<String>,
    Query(params): Query<ListParams>,
    State(state): State<AppState>,
) -> Result<Json<Vec<PinDto>>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    let mut pins = state.store.list_pinned_messages(channel_id).await?;
    if let Some(limit) = params.limit {
        pins.truncate(limit.clamp(1, MAX_PINS_PER_CHANNEL) as usize);
    }
    // Batch-attached exactly as the plain message list does it, so a pin never
    // shows an empty reaction summary just for coming through this endpoint.
    let (messages, meta): (Vec<_>, Vec<_>) = pins
        .into_iter()
        .map(|p| (p.message, (p.pinned_at, p.pinned_by)))
        .unzip();
    let dtos = with_reactions(&state, ctx.user_id, messages).await?;
    let result = dtos
        .into_iter()
        .zip(meta)
        .map(|(message, (pinned_at, pinned_by))| PinDto {
            message,
            pinned_at,
            pinned_by: pinned_by.map(|id| id.to_string()),
        })
        .collect();
    Ok(Json(result))
}

async fn count(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<PinCountDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    let count = state.store.pin_count(channel_id).await?;
    Ok(Json(PinCountDto { count }))
}

/// Checks the caller may both see the channel and manage messages in it.
/// Viewing is checked first and its failure returns the same 403 a missing
/// channel would (see [`Store::permissions_in_channel`]), so a channel's
/// existence is not observable through this route either.
async fn authorize_manage(
    state: &AppState,
    user_id: crate::ids::UserId,
    channel_id: ChannelId,
) -> Result<(), ApiError> {
    if !state
        .store
        .has_permission(user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    if !state
        .store
        .has_permission(user_id, channel_id, Permissions::MANAGE_MESSAGES)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    Ok(())
}
