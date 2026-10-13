// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The join gate's settings, the rules a pending member reads, and accepting
//! them. Enforcement is not here: see `store::member_gate`.

use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_manage_server};
use super::message_validation::parse_uuid;
use crate::hidden_chars::is_hidden_char;
use crate::hub::Event;
use crate::ids::ChannelId;
use crate::ratelimit::Class;
use crate::store::{JoinGate, MAX_RULES_CHARS, MemberGate};

const BODY_LIMIT: usize = 32 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/join-gate", get(read_gate).put(write_gate))
        .route("/space/rules", get(read_rules))
        .route("/space/rules/accept", post(accept))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize, Deserialize)]
struct JoinGateDto {
    enabled: bool,
    rules: String,
    rules_channel_id: Option<String>,
    joins_paused: bool,
}

impl From<JoinGate> for JoinGateDto {
    fn from(gate: JoinGate) -> Self {
        Self {
            enabled: gate.enabled,
            rules: gate.rules,
            rules_channel_id: gate.rules_channel_id.map(|id| id.to_string()),
            joins_paused: gate.joins_paused,
        }
    }
}

#[derive(Serialize)]
struct RulesDto {
    rules: String,
    rules_channel_id: Option<String>,
    /// Whether the caller still has to accept them.
    pending: bool,
}

fn validate_rules(raw: &str) -> Result<String, ApiError> {
    let normalized = raw.replace("\r\n", "\n");
    let trimmed = normalized.trim();
    if trimmed.chars().count() > MAX_RULES_CHARS {
        return Err(ApiError::BadRequest(
            "rules must be 4000 characters or fewer",
        ));
    }
    if trimmed.chars().any(|c| c != '\n' && is_hidden_char(c)) {
        return Err(ApiError::BadRequest(
            "rules must not contain control or invisible characters",
        ));
    }
    Ok(trimmed.to_owned())
}

async fn validate_channel(
    state: &AppState,
    raw: Option<&str>,
) -> Result<Option<ChannelId>, ApiError> {
    let Some(raw) = raw else {
        return Ok(None);
    };
    let id = ChannelId(parse_uuid(raw)?);
    let channel = state.store.channel(id).await?;
    match channel {
        Some(c) if c.kind == "text" && c.parent_message_id.is_none() => Ok(Some(id)),
        _ => Err(ApiError::BadRequest(
            "rules_channel_id must be a text channel",
        )),
    }
}

async fn read_gate(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<JoinGateDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    Ok(Json(state.store.join_gate().await?.into()))
}

/// Everything is validated before the one write, so a refused request
/// changes nothing.
async fn write_gate(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<JoinGateDto>,
) -> Result<Json<JoinGateDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let rules = validate_rules(&body.rules)?;
    if body.enabled && rules.is_empty() {
        return Err(ApiError::BadRequest(
            "write the rules before turning the gate on",
        ));
    }
    let gate = JoinGate {
        enabled: body.enabled,
        rules,
        rules_channel_id: validate_channel(&state, body.rules_channel_id.as_deref()).await?,
        joins_paused: body.joins_paused,
    };
    state.store.set_join_gate(&gate).await?;
    state.hub.publish(Event::JoinGateChanged { user_id: None });
    Ok(Json(gate.into()))
}

async fn read_rules(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<RulesDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    let gate = state.store.join_gate().await?;
    let pending = state.store.member_gate(ctx.user_id).await? != MemberGate::Member;
    Ok(Json(RulesDto {
        rules: gate.rules,
        rules_channel_id: gate.rules_channel_id.map(|id| id.to_string()),
        pending,
    }))
}

/// Idempotent: accepting twice, or with no gate at all, is a 204 that
/// announces nothing.
async fn accept(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    if state.store.accept_rules(ctx.user_id).await? {
        state.hub.publish(Event::JoinGateChanged {
            user_id: Some(ctx.user_id),
        });
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rules_keep_line_breaks_but_refuse_hidden_characters() {
        assert_eq!(
            validate_rules("  be kind\r\nno spam  ").ok(),
            Some("be kind\nno spam".to_owned())
        );
        assert!(validate_rules("be\u{200B}kind").is_err());
        assert!(validate_rules("be\u{7}kind").is_err());
        assert!(validate_rules(&"x".repeat(MAX_RULES_CHARS + 1)).is_err());
        assert!(validate_rules(&"x".repeat(MAX_RULES_CHARS)).is_ok());
    }
}
