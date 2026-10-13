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
use super::hidden_chars::is_hidden_char;
use crate::ratelimit::Class;
use crate::store::{JoinPolicy, MAX_SPACE_DESCRIPTION_CHARS, MAX_SPACE_NAME_CHARS, TotpPolicy};

const BODY_LIMIT: usize = 4 * 1024;

/// The Space settings routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/settings", get(read).patch(update))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct SpaceSettingsDto {
    /// The Space's name, shown in the channel list header and on invites.
    name: String,
    join_policy: String,
    /// `off`, `optional` or `required_for_elevated`; see
    /// [`crate::store::TotpPolicy`].
    #[serde(skip_serializing_if = "Option::is_none")]
    totp_policy: Option<String>,
    /// Shown on the invite landing card; empty means none.
    description: String,
    /// When the banner was last set, or null for none.
    banner_updated_at: Option<i64>,
    /// When the icon was last set, or null for none.
    icon_updated_at: Option<i64>,
}

/// The PATCH body: only the fields present are written.
#[derive(Deserialize)]
struct UpdateSpaceSettingsDto {
    name: Option<String>,
    join_policy: Option<String>,
    totp_policy: Option<String>,
    description: Option<String>,
}

async fn dto(state: &AppState) -> Result<SpaceSettingsDto, ApiError> {
    let landing = state.store.space_landing().await?;
    Ok(SpaceSettingsDto {
        name: state.store.deployment_name().await?,
        join_policy: state.store.join_policy().await?.as_str().to_owned(),
        totp_policy: Some(state.store.totp_policy().await?.as_str().to_owned()),
        description: landing.description,
        banner_updated_at: landing.banner_updated_at,
        icon_updated_at: landing.icon_updated_at,
    })
}

fn validate_description(raw: &str) -> Result<&str, ApiError> {
    let trimmed = raw.trim();
    if trimmed.chars().count() > MAX_SPACE_DESCRIPTION_CHARS {
        return Err(ApiError::BadRequest(
            "description must be 280 characters or fewer",
        ));
    }
    if trimmed.chars().any(is_hidden_char) {
        return Err(ApiError::BadRequest(
            "description must not contain control or invisible characters",
        ));
    }
    Ok(trimmed)
}

fn validate_name(raw: &str) -> Result<&str, ApiError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ApiError::BadRequest("name must not be empty"));
    }
    if trimmed.chars().count() > MAX_SPACE_NAME_CHARS {
        return Err(ApiError::BadRequest("name must be 64 characters or fewer"));
    }
    if trimmed.chars().any(is_hidden_char) {
        return Err(ApiError::BadRequest(
            "name must not contain control or invisible characters",
        ));
    }
    Ok(trimmed)
}

async fn read(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<SpaceSettingsDto>, ApiError> {
    // AuthedRead, not Write: this reads one config value, same as `update` writes one.
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    Ok(Json(dto(&state).await?))
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

    if body.name.is_none()
        && body.join_policy.is_none()
        && body.totp_policy.is_none()
        && body.description.is_none()
    {
        return Err(ApiError::BadRequest(
            "send name, join_policy, totp_policy or description",
        ));
    }
    let name = body.name.as_deref().map(validate_name).transpose()?;
    let description = body
        .description
        .as_deref()
        .map(validate_description)
        .transpose()?;
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
    if let Some(name) = name {
        state.store.set_deployment_name(name).await?;
    }
    if let Some(join) = join {
        state.store.set_join_policy(join).await?;
    }
    if let Some(totp) = totp {
        state.store.set_totp_policy(totp).await?;
    }
    if let Some(description) = description {
        state.store.set_space_description(description).await?;
    }
    Ok(Json(dto(&state).await?))
}
