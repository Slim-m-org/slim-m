// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Menu entries and call controls a bot registers, the list a channel shows,
//! and the route that uses one. The use is an interaction like a button press,
//! so it rides `http::interactions`. See docs/decisions/0045-bot-contributed-ui.md.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, post, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::hidden_chars::is_hidden_char;
use super::interactions::{InteractionDto, record_and_publish};
use super::messages::parse_uuid;
use crate::bot_ui::{self, Surface, UiEntry, UiRegistration};
use crate::hub::Event;
use crate::ids::{ChannelId, InteractionId, MessageId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{Interaction, InteractionKind, VisibleBotUi, now_ms};

const BODY_LIMIT: usize = 16 * 1024;
const VOICE_CHANNEL_KIND: &str = "voice";

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/bots/ui", put(set_ui))
        .route("/channels/{channelId}/bot-ui", get(list_channel_ui))
        .route(
            "/channels/{channelId}/bot-ui/{botId}/interactions",
            post(use_entry),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

/// Bulk-overwrites the caller's own entries; refused for a non-bot.
async fn set_ui(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<UiRegistration>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    if !state.store.is_bot(ctx.user_id).await? {
        return Err(ApiError::Forbidden);
    }
    let reg = bot_ui::validate(body, is_hidden_char).map_err(ApiError::BadRequest)?;
    state.store.set_bot_ui(ctx.user_id, &reg).await?;
    state.hub.publish(Event::BotUiChanged(ctx.user_id));
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Serialize)]
struct BotUiDto {
    bot_user_id: String,
    bot_username: String,
    bot_display_name: String,
    message_menu: Vec<UiEntry>,
    call_controls: Vec<UiEntry>,
}

impl From<VisibleBotUi> for BotUiDto {
    fn from(v: VisibleBotUi) -> Self {
        Self {
            bot_user_id: v.bot_user_id.to_string(),
            bot_username: v.bot_username,
            bot_display_name: v.bot_display_name,
            message_menu: v.message_menu,
            call_controls: v.call_controls,
        }
    }
}

/// What each bot in the channel adds; empty for a caller who cannot view it,
/// the same rule the composer's command list uses.
async fn list_channel_ui(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
    Path(channel_id): Path<String>,
) -> Result<Json<Vec<BotUiDto>>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let caller = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !caller.contains(Permissions::VIEW_CHANNEL) {
        return Ok(Json(Vec::new()));
    }
    let bots = state.store.visible_bot_ui(channel_id, caller).await?;
    Ok(Json(bots.into_iter().map(BotUiDto::from).collect()))
}

#[derive(Deserialize)]
struct UseEntryRequest {
    /// Chosen by the client, so a retried use is the same use.
    id: String,
    surface: Surface,
    entry_id: String,
    /// The message a menu entry was used on; absent for a call control.
    #[serde(default)]
    message_id: Option<String>,
    /// The choice made on a call control that offers options; absent otherwise.
    #[serde(default)]
    option_id: Option<String>,
}

/// A member uses a bot's entry. Every refusal that depends on the bot, the
/// entry or the message is the same 404, so the route is not an oracle for
/// what a channel holds.
async fn use_entry(
    Authed(ctx): Authed,
    Path((channel_id, bot_id)): Path<(String, String)>,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<UseEntryRequest>,
) -> Result<Json<InteractionDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Interaction)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let bot_id = UserId(parse_uuid(&bot_id)?);
    let id = InteractionId(parse_uuid(&req.id)?);
    let caller = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !caller.contains(Permissions::VIEW_CHANNEL) || state.store.is_bot(ctx.user_id).await? {
        return Err(ApiError::Forbidden);
    }
    const GONE: ApiError = ApiError::NotFound("entry not found");
    let bot_can_hear = state.store.bot_is_live(bot_id).await?
        && state
            .store
            .has_permission(bot_id, channel_id, Permissions::VIEW_CHANNEL)
            .await?;
    if !bot_can_hear {
        return Err(GONE);
    }
    let entry = state
        .store
        .bot_ui_entry(bot_id, req.surface, &req.entry_id)
        .await?
        .ok_or(GONE)?;
    if let Some(bit) = entry.permission
        && !caller.contains(Permissions::from_bits(bit))
    {
        return Err(GONE);
    }
    let (message_id, kind) = match req.surface {
        Surface::MessageMenu => {
            let raw = req.message_id.as_deref().ok_or(ApiError::BadRequest(
                "a menu entry names the message it was used on",
            ))?;
            let message_id = MessageId(parse_uuid(raw)?);
            let message = state.store.message(message_id).await?;
            if message.is_none_or(|m| m.channel_id != channel_id) {
                return Err(GONE);
            }
            (Some(message_id), InteractionKind::MessageMenu)
        }
        Surface::CallControl => {
            if req.message_id.is_some() {
                return Err(ApiError::BadRequest("a call control names no message"));
            }
            require_in_call(&state, ctx.user_id, channel_id).await?;
            if !state.voice.has_heartbeat(bot_id, channel_id) {
                return Err(GONE);
            }
            (None, InteractionKind::CallControl)
        }
    };
    let option_id = chosen_option(&entry, req.option_id)?;
    let display_name = state
        .store
        .user_profile(ctx.user_id)
        .await?
        .ok_or(ApiError::Forbidden)?
        .display_name;
    let fresh = Interaction {
        id,
        bot_id,
        clicker_id: ctx.user_id,
        channel_id,
        message_id,
        custom_id: entry.id,
        kind,
        option_id,
        created_at: now_ms(),
        answered: false,
    };
    record_and_publish(&state, fresh, display_name).await
}

/// A control that offers options needs one of them, and nothing else takes
/// one. An option the bot no longer offers is the same 404 as a dropped entry,
/// since a re-registration can remove it between listing and use.
fn chosen_option(entry: &UiEntry, option_id: Option<String>) -> Result<Option<String>, ApiError> {
    match (entry.options.is_empty(), option_id) {
        (true, None) => Ok(None),
        (true, Some(_)) => Err(ApiError::BadRequest("this entry offers no options")),
        (false, None) => Err(ApiError::BadRequest("this call control needs an option_id")),
        (false, Some(id)) if entry.options.iter().any(|o| o.id == id) => Ok(Some(id)),
        (false, Some(_)) => Err(ApiError::NotFound("entry not found")),
    }
}

/// A call control acts on a live call, so the member must be on it: viewing a
/// voice channel is not the same as being in its call.
async fn require_in_call(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
) -> Result<(), ApiError> {
    let channel = state
        .store
        .channel(channel_id)
        .await?
        .ok_or(ApiError::NotFound("entry not found"))?;
    if channel.kind != VOICE_CHANNEL_KIND || !state.voice.has_heartbeat(user_id, channel_id) {
        return Err(ApiError::Forbidden);
    }
    Ok(())
}
