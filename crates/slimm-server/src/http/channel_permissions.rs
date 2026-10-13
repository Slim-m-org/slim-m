// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /channels/{channel_id}/permissions`: the caller's effective
//! permission bitmask in one channel, the per-channel sibling `GET /me`'s
//! deployment-wide bitmask has never answered. See
//! docs/decisions/0011-per-channel-permissions.md for the design, and why
//! this exists at all - seven client sites gate an action on the wrong
//! bitmask because nothing until now let them ask the right one.

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::extract::{Path, State};
use axum::routing::get;
use serde::Serialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json};
use super::messages::parse_uuid;
use crate::ids::ChannelId;
use crate::permissions::mask_unless_viewable;

/// Every body here is a small JSON document; refused well before axum's 2 MB default.
const BODY_LIMIT: usize = 64 * 1024;

/// The channel-permission route, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/permissions", get(get_permissions))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct ChannelPermissionsDto {
    permissions: i64,
}

/// Calls [`crate::store::Store::permissions_in_channel`] - which already
/// resolves a thread to its parent, branches to the DM evaluator, and
/// subtracts a timeout - then masks the whole answer with
/// [`mask_unless_viewable`] whenever the result lacks VIEW_CHANNEL.
///
/// That masking is not caution for its own sake. `permissions_in_channel`
/// forces `NONE` for a channel that does not exist, but a real channel the
/// caller cannot view still passes its base bits straight through unless an
/// overwrite happens to deny them, and `@everyone` usually grants something.
/// Left unmasked, this route would answer differently for those two cases
/// and become a channel-existence oracle, the exact leak `http::sync`
/// already goes out of its way to avoid. So "no such channel" and "not
/// permitted here" refuse identically, the same precedent `overwrites.rs`
/// already states for this API.
async fn get_permissions(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ChannelPermissionsDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    Ok(Json(ChannelPermissionsDto {
        permissions: mask_unless_viewable(permissions).bits(),
    }))
}
