// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A per-(caller, channel) override of the account-wide notification
//! preference (`GET`/`PUT /push/preference`): mute one channel entirely, or
//! narrow it to mentions only, while every other channel keeps following the
//! account default.
//!
//! `everything` is refused here: having no row already means that, so
//! writing it would be a second spelling of the same answer rather than a
//! real override, and `DELETE` is the one way back to "follow the account
//! default". Enforced exactly once, in
//! `push::recipients::narrow_for_notification_preference` - the account-wide
//! preference's own choke point, extended rather than duplicated - never a
//! filter a client applies after a device has already buzzed.

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelId, UserId};
use crate::notifications::NotificationPreference;
use crate::permissions::Permissions;
use crate::ratelimit::Class;

/// Every body here is a small JSON document; refused well before axum's 2 MB default.
const BODY_LIMIT: usize = 64 * 1024;

/// The channel-override routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/notification-preferences/channels", get(list))
        .route(
            "/notification-preferences/channels/{channel_id}",
            put(set).delete(clear),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

// --- Wire types ---

#[derive(Serialize)]
struct ChannelPreferenceDto {
    channel_id: String,
    preference: String,
}

#[derive(Deserialize)]
struct SetRequest {
    preference: String,
}

// --- Handlers ---

/// Every channel the caller has overridden, id and preference only - a
/// channel following the account default carries no row and is absent here,
/// never listed at `everything`. Unfiltered by the caller's current view of
/// each channel: every id here is one the caller set themselves, so this
/// tells them nothing they did not already know.
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<ChannelPreferenceDto>>, ApiError> {
    let rows = state
        .store
        .list_channel_notification_preferences(ctx.user_id)
        .await?;
    Ok(Json(
        rows.into_iter()
            .map(|(channel_id, preference)| ChannelPreferenceDto {
                channel_id: channel_id.to_string(),
                preference: preference.as_str().to_owned(),
            })
            .collect(),
    ))
}

/// Sets the caller's own override for one channel. Requires VIEW_CHANNEL,
/// the same bar reading the channel's messages already sets - muting a
/// channel the caller cannot see would be a no-op with no way to confirm it,
/// and gating it this way keeps a channel's existence no more observable
/// through this route than through any other (see
/// `docs/decisions/0011-per-channel-permissions.md`).
async fn set(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<SetRequest>,
) -> Result<Json<ChannelPreferenceDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let preference = NotificationPreference::parse(&req.preference)
        .filter(|p| *p != NotificationPreference::Everything)
        .ok_or(ApiError::BadRequest(
            "preference must be mentions or nothing - everything is what clearing the override already means",
        ))?;
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    let before = state
        .store
        .channel_notification_preference(ctx.user_id, channel_id)
        .await?;
    state
        .store
        .set_channel_notification_preference(ctx.user_id, channel_id, preference)
        .await?;
    if before != Some(preference) {
        announce(&state, ctx.user_id, channel_id, Some(preference));
    }
    Ok(Json(ChannelPreferenceDto {
        channel_id: channel_id.to_string(),
        preference: preference.as_str().to_owned(),
    }))
}

/// Clears the caller's own override, reverting the channel to the account
/// default. No permission check: this only ever touches the caller's own
/// row, keyed on their own id, so clearing it after losing view access to
/// the channel leaks nothing a `VIEW_CHANNEL` gate would have protected.
async fn clear(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let before = state
        .store
        .channel_notification_preference(ctx.user_id, channel_id)
        .await?;
    state
        .store
        .clear_channel_notification_preference(ctx.user_id, channel_id)
        .await?;
    if before.is_some() {
        announce(&state, ctx.user_id, channel_id, None);
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Tells the account's own sockets; a write that changed nothing is not
/// announced, since the frame wakes every socket on the shared channel.
fn announce(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
    preference: Option<NotificationPreference>,
) {
    state.hub.publish(Event::NotificationOverrideChanged {
        user_id,
        channel_id,
        preference,
    });
}
