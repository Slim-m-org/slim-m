// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deployment-wide settings, read and written by an administrator.
//!
//! Reading is gated the same as writing rather than being open to any member.
//! Whether a Space is open to join is already public through `/version`, which
//! onboarding needs before an account exists; this route exists so the one
//! screen that can change it can also show what it is now, and gating both on
//! the same bit means nothing else about a deployment's configuration becomes
//! member-readable when a second setting lands here.

use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::require_manage_server;
use super::extract::{Authed, Json, enforce};
use crate::ratelimit::Class;
use crate::store::{JoinPolicy, TotpPolicy};

const BODY_LIMIT: usize = 1024;

/// The Space settings routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/settings", get(read).patch(update))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct SpaceSettingsDto {
    join_policy: String,
    /// `off`, `optional` or `required_for_elevated`; see
    /// [`crate::store::TotpPolicy`].
    #[serde(skip_serializing_if = "Option::is_none")]
    totp_policy: Option<String>,
}

/// The PATCH body: only the fields present are written.
#[derive(Deserialize)]
struct UpdateSpaceSettingsDto {
    join_policy: Option<String>,
    totp_policy: Option<String>,
}

async fn read(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<SpaceSettingsDto>, ApiError> {
    // AuthedRead, not Write: this reads one config value, same as `update` writes one.
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    Ok(Json(SpaceSettingsDto {
        join_policy: state.store.join_policy().await?.as_str().to_owned(),
        totp_policy: Some(state.store.totp_policy().await?.as_str().to_owned()),
    }))
}

/// An unrecognised policy is refused rather than coerced, so a typo cannot
/// silently leave a Space on whichever branch the parser defaults to.
async fn update(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<UpdateSpaceSettingsDto>,
) -> Result<Json<SpaceSettingsDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;

    if body.join_policy.is_none() && body.totp_policy.is_none() {
        return Err(ApiError::BadRequest(
            "send join_policy, totp_policy or both",
        ));
    }
    let join = match body.join_policy.as_deref() {
        Some("invite") => Some(JoinPolicy::Invite),
        Some("open") => Some(JoinPolicy::Open),
        Some(_) => return Err(ApiError::BadRequest("join_policy must be invite or open")),
        None => None,
    };
    // Parsed before either write, so a bad value cannot leave the join policy changed and the request refused.
    let totp = match body.totp_policy.as_deref() {
        Some(value) => Some(TotpPolicy::parse(value).ok_or(ApiError::BadRequest(
            "totp_policy must be off, optional or required_for_elevated",
        ))?),
        None => None,
    };
    if let Some(join) = join {
        state.store.set_join_policy(join).await?;
    }
    if let Some(totp) = totp {
        state.store.set_totp_policy(totp).await?;
    }
    Ok(Json(SpaceSettingsDto {
        join_policy: state.store.join_policy().await?.as_str().to_owned(),
        totp_policy: Some(state.store.totp_policy().await?.as_str().to_owned()),
    }))
}
