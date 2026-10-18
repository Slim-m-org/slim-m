// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Provisioning bots, gated on MANAGE_SERVER, plus their managed role and
//! permission declaration. See `docs/decisions/0028-bot-accounts.md`.
//!
//! The token is returned exactly once, by [`create`], and unrecoverable
//! afterwards.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, patch, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::auth::{validate_label, validate_username};
use super::error::ApiError;
use super::escalation::escalation_guard;
use super::extract::{Authed, Json, Query, enforce, require_human, require_manage_server};
use super::messages::parse_uuid;
use super::roles::grantable;
use crate::hub::Event;
use crate::ids::UserId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{Bot, CreateBotError, UpdateBotPermissionsError, validate_bot_prefix};

const BODY_LIMIT: usize = 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/bots", get(list).post(create))
        .route("/bots/suggested-prefix", get(suggested_prefix))
        .route("/bots/{bot_id}/revoke", post(revoke))
        .route("/bots/{bot_id}/permissions", patch(set_permissions))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct CreateBotDto {
    username: String,
    display_name: Option<String>,
    /// The bot's managed-role grant. Defaults to none.
    #[serde(default)]
    permissions: i64,
    /// The prefix this bot answers to; a free one is picked when absent.
    prefix: Option<String>,
}

#[derive(Serialize)]
struct SuggestedPrefixDto {
    prefix: String,
}

#[derive(Deserialize)]
struct SetBotPermissionsRequest {
    permissions: i64,
}

#[derive(Deserialize)]
struct ListBotsParams {
    #[serde(default)]
    include_removed: bool,
}

#[derive(Serialize)]
struct BotDto {
    user_id: String,
    username: String,
    display_name: String,
    created_at: i64,
    /// Absent once revoked, so a reader can see at a glance that this bot can
    /// no longer act.
    token_name: Option<String>,
    token_last_used_at: Option<i64>,
    /// The bot's managed role. `None` once revoked.
    role_id: Option<String>,
    /// What that role currently grants; `0` once revoked.
    permissions: i64,
    /// The prefix assigned to this bot; absent until one is assigned or adopted.
    #[serde(skip_serializing_if = "Option::is_none")]
    prefix: Option<String>,
}

impl From<Bot> for BotDto {
    fn from(bot: Bot) -> Self {
        Self {
            user_id: bot.user_id.to_string(),
            username: bot.username,
            display_name: bot.display_name,
            created_at: bot.created_at,
            token_name: bot.token_name,
            token_last_used_at: bot.token_last_used_at,
            role_id: bot.role_id.map(|id| id.to_string()),
            permissions: bot.permissions.bits(),
            prefix: bot.prefix,
        }
    }
}

/// A created bot, with its token. The only response that ever carries one.
#[derive(Serialize)]
struct NewBotDto {
    bot: BotDto,
    token: String,
}

async fn caller_granted(state: &AppState, user_id: UserId) -> Result<Permissions, ApiError> {
    Ok(state.store.granted_base_permissions(user_id).await?)
}

async fn list(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Query(params): Query<ListBotsParams>,
) -> Result<Json<Vec<BotDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    let bots = state.store.list_bots(params.include_removed).await?;
    Ok(Json(bots.into_iter().map(BotDto::from).collect()))
}

/// A prefix no live bot holds, for the create form to offer.
async fn suggested_prefix(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<SuggestedPrefixDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    Ok(Json(SuggestedPrefixDto {
        prefix: state.store.suggest_bot_prefix().await?,
    }))
}

/// Bot names follow the same rules a person's username does, so a bot is
/// mentionable and addressable exactly as any member is. That means calling
/// registration's own validators rather than restating them here: the inline
/// copies this replaced checked length and charset only, so a bot could hold a
/// reserved `@everyone`/`@here` name and a display name carrying a
/// right-to-left override that a person is refused at register and at `/me`.
async fn create(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<CreateBotDto>,
) -> Result<(StatusCode, Json<NewBotDto>), ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    require_human(&state, ctx.user_id).await?;

    let username = body.username.trim();
    validate_username(username)?;
    let display_name = body
        .display_name
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .unwrap_or(username);
    validate_label(display_name, "display_name must be 1 to 64 characters")?;

    // Effective, like `http::roles::create`'s identical read; see this file's own doc.
    let caller_effective = state.store.base_permissions(ctx.user_id).await?;
    let permissions = grantable(caller_effective, body.permissions)?;

    let prefix = match body.prefix.as_deref().map(str::trim) {
        Some(prefix) => {
            validate_bot_prefix(prefix).map_err(ApiError::BadRequest)?;
            prefix.to_owned()
        }
        None => state.store.suggest_bot_prefix().await?,
    };

    match state
        .store
        .create_bot_with_prefix(
            username,
            display_name,
            permissions,
            ctx.user_id,
            Some(&prefix),
        )
        .await
    {
        Ok(new_bot) => Ok((
            StatusCode::CREATED,
            Json(NewBotDto {
                bot: new_bot.bot.into(),
                token: new_bot.token,
            }),
        )),
        Err(CreateBotError::UsernameTaken) => Err(ApiError::Conflict("that username is taken")),
        Err(CreateBotError::Internal(err)) => Err(err.into()),
    }
}

/// Revokes a bot's token and session. The account and its roles stay.
async fn revoke(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(bot_id): Path<String>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let bot_id = UserId(parse_uuid(&bot_id)?);
    let Some(revoked) = state.store.revoke_bot(bot_id, ctx.user_id).await? else {
        return Err(ApiError::NotFound("no such bot"));
    };
    for session_id in revoked {
        state.hub.publish(Event::SessionRevoked(session_id));
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Changes what a bot's managed role grants; see
/// `docs/decisions/0028-bot-accounts.md`.
async fn set_permissions(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(bot_id): Path<String>,
    Json(req): Json<SetBotPermissionsRequest>,
) -> Result<Json<BotDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    require_human(&state, ctx.user_id).await?;
    let bot_id = UserId(parse_uuid(&bot_id)?);

    let current = state
        .store
        .role_for_bot(bot_id)
        .await?
        .ok_or(ApiError::NotFound("no such bot"))?;
    escalation_guard(
        caller_granted(&state, ctx.user_id).await?,
        current.permissions,
    )?;

    let caller_effective = state.store.base_permissions(ctx.user_id).await?;
    let permissions = grantable(caller_effective, req.permissions)?;

    match state
        .store
        .update_bot_permissions(bot_id, ctx.user_id, permissions)
        .await
    {
        Ok(bot) => {
            state.hub.publish(Event::RoleChanged {
                role_id: current.id,
            });
            Ok(Json(bot.into()))
        }
        Err(UpdateBotPermissionsError::NoSuchBot) => Err(ApiError::NotFound("no such bot")),
        Err(UpdateBotPermissionsError::Internal(err)) => Err(err.into()),
    }
}
