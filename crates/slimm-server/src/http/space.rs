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
use super::messages::parse_uuid;
use crate::ids::ChannelId;
use crate::ratelimit::Class;
use crate::store::{
    JoinPolicy, MAX_SPACE_DESCRIPTION_CHARS, MAX_SPACE_NAME_CHARS, MAX_WELCOME_MESSAGE_CHARS,
    SpaceWelcome, TotpPolicy,
};

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
    /// What "Space default" means for members' noise suppression.
    strong_noise_suppression: bool,
    /// Whether every member may create invites, not only holders of CREATE_INVITE.
    members_can_invite: bool,
    /// Whether a welcome message is posted when someone joins.
    welcome_enabled: bool,
    /// Where the welcome is posted, or null for none.
    welcome_channel_id: Option<String>,
    /// The welcome template; `{user}` and `{space}` are filled in.
    welcome_message: String,
}

/// The PATCH body: only the fields present are written.
#[derive(Deserialize)]
struct UpdateSpaceSettingsDto {
    name: Option<String>,
    join_policy: Option<String>,
    totp_policy: Option<String>,
    description: Option<String>,
    strong_noise_suppression: Option<bool>,
    members_can_invite: Option<bool>,
    welcome_enabled: Option<bool>,
    /// An empty string clears the channel.
    welcome_channel_id: Option<String>,
    welcome_message: Option<String>,
}

async fn dto(state: &AppState) -> Result<SpaceSettingsDto, ApiError> {
    let landing = state.store.space_landing().await?;
    let welcome = state.store.space_welcome().await?;
    Ok(SpaceSettingsDto {
        name: state.store.deployment_name().await?,
        join_policy: state.store.join_policy().await?.as_str().to_owned(),
        totp_policy: Some(state.store.totp_policy().await?.as_str().to_owned()),
        description: landing.description,
        banner_updated_at: landing.banner_updated_at,
        icon_updated_at: landing.icon_updated_at,
        strong_noise_suppression: state.store.strong_noise_suppression().await?,
        members_can_invite: state.store.members_can_invite().await?,
        welcome_enabled: welcome.enabled,
        welcome_channel_id: welcome.channel_id.map(|id| id.to_string()),
        welcome_message: welcome.message,
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

/// The welcome settings after this PATCH, or `None` when it names none of them.
/// Turning it on needs a text channel and a message, so a half-set welcome is refused.
async fn merged_welcome(
    state: &AppState,
    body: &UpdateSpaceSettingsDto,
) -> Result<Option<SpaceWelcome>, ApiError> {
    if body.welcome_enabled.is_none()
        && body.welcome_channel_id.is_none()
        && body.welcome_message.is_none()
    {
        return Ok(None);
    }
    let mut welcome = state.store.space_welcome().await?;
    if let Some(enabled) = body.welcome_enabled {
        welcome.enabled = enabled;
    }
    if let Some(raw) = body.welcome_channel_id.as_deref().map(str::trim) {
        welcome.channel_id = match raw {
            "" => None,
            raw => {
                let id = ChannelId(parse_uuid(raw)?);
                let channel = state.store.channel(id).await?;
                if channel.is_none_or(|c| c.kind != "text") {
                    return Err(ApiError::BadRequest(
                        "welcome_channel_id must be a text channel",
                    ));
                }
                Some(id)
            }
        };
    }
    if let Some(raw) = body.welcome_message.as_deref() {
        welcome.message = validate_welcome_message(raw)?.to_owned();
    }
    if welcome.enabled && (welcome.channel_id.is_none() || welcome.message.is_empty()) {
        return Err(ApiError::BadRequest(
            "a welcome needs a channel and a message before it can be turned on",
        ));
    }
    Ok(Some(welcome))
}

fn validate_welcome_message(raw: &str) -> Result<&str, ApiError> {
    let trimmed = raw.trim();
    if trimmed.chars().count() > MAX_WELCOME_MESSAGE_CHARS {
        return Err(ApiError::BadRequest(
            "welcome_message must be 500 characters or fewer",
        ));
    }
    if trimmed.chars().any(|c| c != '\n' && is_hidden_char(c)) {
        return Err(ApiError::BadRequest(
            "welcome_message must not contain control or invisible characters",
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

/// Turning the switch off ends the invites members already made, and says so in the audit log.
async fn revoke_member_invites(
    state: &AppState,
    actor: crate::ids::UserId,
) -> Result<(), ApiError> {
    let revoked = state.store.revoke_invites_without_rights().await?;
    if revoked > 0 {
        let detail = serde_json::json!({ "count": revoked }).to_string();
        state
            .store
            .record_admin_change(actor, "invite.revoke_members", None, &detail)
            .await?;
    }
    Ok(())
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
        && body.strong_noise_suppression.is_none()
        && body.members_can_invite.is_none()
        && body.welcome_enabled.is_none()
        && body.welcome_channel_id.is_none()
        && body.welcome_message.is_none()
    {
        return Err(ApiError::BadRequest(
            "send name, join_policy, totp_policy, description, strong_noise_suppression, members_can_invite or a welcome field",
        ));
    }
    let welcome = merged_welcome(&state, &body).await?;
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
    if let Some(enabled) = body.strong_noise_suppression {
        state.store.set_strong_noise_suppression(enabled).await?;
    }
    if let Some(enabled) = body.members_can_invite {
        state.store.set_members_can_invite(enabled).await?;
        if !enabled {
            revoke_member_invites(&state, ctx.user_id).await?;
        }
    }
    if let Some(welcome) = welcome {
        state.store.set_space_welcome(&welcome).await?;
    }
    Ok(Json(dto(&state).await?))
}
