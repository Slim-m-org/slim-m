// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Buttons on a bot's own message: the send-path helpers and the route a bot
//! uses to replace or clear them. See docs/decisions/0039-bot-message-buttons.md.

use std::sync::Arc;

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::extract::{Path, State};
use axum::http::request::Parts;
use axum::routing::put;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::interactions::{answer, own_interaction};
use super::messages::parse_uuid;
use crate::components::{self, ComponentRow};
use crate::hub::Event;
use crate::ids::{ChannelId, InteractionId, MessageId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;

/// Every body here is a small JSON document; refused well before axum's 2 MB default.
const BODY_LIMIT: usize = 64 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/channels/{channelId}/messages/{messageId}/components",
            put(set_components),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

/// `raw` checked against the caps. Only a bot may attach buttons, and saying
/// so beats dropping them silently: the caller is a program that would
/// otherwise never learn its buttons were discarded.
pub(super) async fn honored_for_send(
    state: &AppState,
    caller: UserId,
    raw: Vec<ComponentRow>,
) -> Result<Vec<ComponentRow>, ApiError> {
    if raw.is_empty() {
        return Ok(raw);
    }
    if !state.store.is_bot(caller).await? {
        return Err(ApiError::Forbidden);
    }
    components::validate(raw, super::hidden_chars::is_hidden_char).map_err(ApiError::BadRequest)
}

/// Stores `rows` when `fresh`, then reads back what the message really has, so
/// an idempotent retry returns the buttons as they are now.
pub(super) async fn store_and_reload(
    state: &AppState,
    message_id: MessageId,
    fresh: bool,
    rows: &[ComponentRow],
) -> anyhow::Result<Vec<ComponentRow>> {
    if fresh && !rows.is_empty() {
        state.store.set_message_components(message_id, rows).await?;
    }
    state.store.components_for_message(message_id).await
}

#[derive(Deserialize)]
struct SetComponentsRequest {
    /// The whole new list; empty clears every button.
    components: Vec<ComponentRow>,
    /// The click this change answers, if any.
    #[serde(default)]
    interaction_id: Option<String>,
}

#[derive(Serialize)]
struct ComponentsDto {
    components: Vec<ComponentRow>,
}

/// A bot replaces the buttons on a message it authored, for example to disable
/// them once a choice is made. Every viewer is told over the socket.
async fn set_components(
    Authed(ctx): Authed,
    Path((channel_id, message_id)): Path<(String, String)>,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<SetComponentsRequest>,
) -> Result<Json<ComponentsDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let message_id = MessageId(parse_uuid(&message_id)?);
    let interaction_id = req
        .interaction_id
        .as_deref()
        .map(|raw| parse_uuid(raw).map(InteractionId))
        .transpose()?;
    let rows = components::validate(req.components, super::hidden_chars::is_hidden_char)
        .map_err(ApiError::BadRequest)?;
    let needed = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    if !state.store.is_bot(ctx.user_id).await?
        || !state
            .store
            .has_permission(ctx.user_id, channel_id, needed)
            .await?
    {
        return Err(ApiError::Forbidden);
    }
    let message = state
        .store
        .message(message_id)
        .await?
        .filter(|m| m.channel_id == channel_id)
        .ok_or(ApiError::NotFound("message not found"))?;
    if message.author_id != Some(ctx.user_id) {
        return Err(ApiError::Forbidden);
    }
    // Checked before anything changes: a bad press id must not leave the buttons half-updated.
    let press = match interaction_id {
        Some(id) => Some(own_interaction(&state, ctx.user_id, channel_id, id).await?),
        None => None,
    };
    if press
        .as_ref()
        .is_some_and(|p| p.message_id != Some(message_id))
    {
        return Err(ApiError::NotFound("interaction not found"));
    }
    state
        .store
        .set_message_components(message_id, &rows)
        .await?;
    state.hub.publish(Event::MessageComponentsChanged {
        channel_id,
        message_id,
        components: Arc::new(rows.clone()),
    });
    if let Some(press) = &press {
        answer(&state, press).await?;
    }
    Ok(Json(ComponentsDto { components: rows }))
}
