// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot answers a press by opening a small form, and the member's submission
//! reaches the bot as an interaction of its own. See
//! docs/decisions/0083-bot-token-reissue-select-menus-and-forms.md.

use std::collections::BTreeMap;
use std::sync::Arc;

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::post;
use serde::Deserialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::hidden_chars::is_hidden_char;
use super::interactions::require_live_bot;
use super::interactions::{InteractionDto, answer, own_interaction, record_and_publish};
use super::messages::parse_uuid;
use crate::components::form::{self, Form};
use crate::hub::Event;
use crate::ids::{ChannelId, InteractionId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{Interaction, InteractionInput, InteractionKind, now_ms};

/// Both bodies are a few short fields; refused well before axum's 2 MB default.
const BODY_LIMIT: usize = 64 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/channels/{channelId}/interactions/{interactionId}/form",
            post(open),
        )
        .route(
            "/channels/{channelId}/interactions/{interactionId}/submit",
            post(submit),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

/// The bot opens a form for the member whose press it received. That answers
/// the press, so the member's button stops waiting.
async fn open(
    Authed(ctx): Authed,
    Path((channel_id, interaction_id)): Path<(String, String)>,
    parts: Parts,
    State(state): State<AppState>,
    Json(mut form): Json<Form>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let id = InteractionId(parse_uuid(&interaction_id)?);
    form::validate(&mut form, is_hidden_char).map_err(ApiError::BadRequest)?;
    let interaction = own_interaction(&state, ctx.user_id, channel_id, id).await?;
    if !state.store.set_interaction_form(id, &form).await? {
        return Err(ApiError::Conflict("this press already opened a form"));
    }
    answer(&state, &interaction).await?;
    state.hub.publish(Event::InteractionForm {
        interaction: Arc::new(interaction),
        form: Arc::new(form),
    });
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct SubmitRequest {
    /// Chosen by the client, so a retried submission is the same one.
    id: String,
    #[serde(default)]
    fields: BTreeMap<String, String>,
}

/// The member sends their answers to the form the bot opened for them. Any
/// refusal that depends on the press, the form or the bot is the same 404.
async fn submit(
    Authed(ctx): Authed,
    Path((channel_id, interaction_id)): Path<(String, String)>,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<SubmitRequest>,
) -> Result<Json<InteractionDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Interaction)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let origin_id = InteractionId(parse_uuid(&interaction_id)?);
    let id = InteractionId(parse_uuid(&req.id)?);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
        || state.store.is_bot(ctx.user_id).await?
    {
        return Err(ApiError::Forbidden);
    }
    const GONE: ApiError = ApiError::NotFound("form not found");
    let origin = state
        .store
        .interaction(origin_id)
        .await?
        .filter(|i| i.clicker_id == ctx.user_id && i.channel_id == channel_id)
        .ok_or(GONE)?;
    let form = state.store.interaction_form(origin_id).await?.ok_or(GONE)?;
    require_live_bot(&state, origin.bot_id, channel_id).await?;
    let fields = form
        .check_answers(req.fields, is_hidden_char)
        .map_err(ApiError::BadRequest)?;
    let display_name = state
        .store
        .user_profile(ctx.user_id)
        .await?
        .ok_or(ApiError::Forbidden)?
        .display_name;
    let fresh = Interaction {
        id,
        bot_id: origin.bot_id,
        clicker_id: ctx.user_id,
        channel_id,
        message_id: origin.message_id,
        custom_id: form.custom_id,
        kind: InteractionKind::FormSubmit,
        option_id: None,
        created_at: now_ms(),
        answered: false,
    };
    let input = InteractionInput {
        fields,
        ..InteractionInput::default()
    };
    record_and_publish(&state, fresh, display_name, input).await
}
