// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bot command registration routes: register, read one bot's set, and the
//! composer's channel-scoped discovery list. See
//! docs/decisions/0031-bot-command-registration.md.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json};
use super::messages::parse_uuid;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{BotCommand, SetBotCommandsError, VisibleBotCommand};

/// Lists newly added command names left out because another bot holds them.
const DROPPED_HEADER: &str = "x-slimm-dropped-commands";
const BODY_LIMIT: usize = 16 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/bots/commands", put(set_commands))
        .route("/bots/{botId}/commands", get(get_commands))
        .route(
            "/channels/{channelId}/bot-commands",
            get(list_channel_commands),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct BotCommandDto {
    name: String,
    description: String,
    #[serde(default)]
    usage: Option<String>,
    #[serde(default)]
    permission: Option<i64>,
}

impl From<BotCommandDto> for BotCommand {
    fn from(dto: BotCommandDto) -> Self {
        Self {
            name: dto.name,
            description: dto.description,
            usage: dto.usage,
            permission: dto.permission,
        }
    }
}

#[derive(Deserialize)]
struct SetBotCommandsRequest {
    prefix: String,
    #[serde(default)]
    commands: Vec<BotCommandDto>,
}

/// A bot's own registered set, unfiltered by any viewer's channel.
#[derive(Serialize)]
struct BotCommandRegistrationDto {
    /// Absent for a bot that has never registered anything.
    prefix: Option<String>,
    commands: Vec<RegisteredCommandDto>,
}

#[derive(Serialize)]
struct RegisteredCommandDto {
    name: String,
    description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    usage: Option<String>,
}

/// Bulk-overwrites the caller's own registration; refused for a non-bot.
async fn set_commands(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<SetBotCommandsRequest>,
) -> Result<Response, ApiError> {
    super::extract::enforce(&state, &parts, Some(&ctx), Class::Write)?;
    if !state.store.is_bot(ctx.user_id).await? {
        return Err(ApiError::Forbidden);
    }
    let commands: Vec<BotCommand> = body.commands.into_iter().map(BotCommand::from).collect();
    match state
        .store
        .set_bot_commands(ctx.user_id, &body.prefix, &commands)
        .await
    {
        Ok(dropped) if dropped.is_empty() => Ok(StatusCode::NO_CONTENT.into_response()),
        Ok(dropped) => {
            tracing::warn!(bot = %ctx.user_id, ?dropped, "bot command names already taken were not registered");
            Ok((
                StatusCode::NO_CONTENT,
                [(DROPPED_HEADER, dropped.join(","))],
            )
                .into_response())
        }
        Err(SetBotCommandsError::TooManyCommands) => Err(ApiError::BadRequest(
            "a bot may register at most 50 commands",
        )),
        Err(SetBotCommandsError::InvalidPrefix(msg) | SetBotCommandsError::InvalidCommand(msg)) => {
            Err(ApiError::BadRequest(msg))
        }
        Err(SetBotCommandsError::PrefixNotAssigned { assigned }) => Err(ApiError::ConflictDetail(
            format!("this bot is assigned the prefix {assigned}; register under it"),
        )),
        Err(SetBotCommandsError::Internal(err)) => Err(err.into()),
    }
}

/// A bot's whole registration; empty for one that never registered.
async fn get_commands(
    AuthedLimited(_ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
    Path(bot_id): Path<String>,
) -> Result<Json<BotCommandRegistrationDto>, ApiError> {
    let bot_id = UserId(parse_uuid(&bot_id)?);
    let registration = state.store.bot_commands(bot_id).await?;
    Ok(Json(match registration {
        Some(reg) => BotCommandRegistrationDto {
            prefix: Some(reg.prefix),
            commands: reg
                .commands
                .into_iter()
                .map(|c| RegisteredCommandDto {
                    name: c.name,
                    description: c.description,
                    usage: c.usage,
                })
                .collect(),
        },
        None => BotCommandRegistrationDto {
            prefix: None,
            commands: Vec::new(),
        },
    }))
}

#[derive(Serialize)]
struct ChannelBotCommandDto {
    bot_user_id: String,
    bot_username: String,
    bot_display_name: String,
    prefix: String,
    name: String,
    description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    usage: Option<String>,
}

impl From<VisibleBotCommand> for ChannelBotCommandDto {
    fn from(v: VisibleBotCommand) -> Self {
        Self {
            bot_user_id: v.bot_user_id.to_string(),
            bot_username: v.bot_username,
            bot_display_name: v.bot_display_name,
            prefix: v.prefix,
            name: v.command.name,
            description: v.command.description,
            usage: v.command.usage,
        }
    }
}

/// The composer's discovery list; masked to empty for a caller lacking
/// VIEW_CHANNEL, the same rule `getChannelPermissions` uses.
async fn list_channel_commands(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
    Path(channel_id): Path<String>,
) -> Result<Json<Vec<ChannelBotCommandDto>>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let caller_permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !caller_permissions.contains(Permissions::VIEW_CHANNEL) {
        return Ok(Json(Vec::new()));
    }
    let commands = state
        .store
        .visible_bot_commands(channel_id, caller_permissions)
        .await?;
    Ok(Json(
        commands
            .into_iter()
            .map(ChannelBotCommandDto::from)
            .collect(),
    ))
}
