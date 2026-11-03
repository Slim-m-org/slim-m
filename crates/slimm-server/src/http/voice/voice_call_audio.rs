// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Asking, answering and stopping a module hearing a voice call (decision
//! 0105). Each route changes the in-memory session and hands the outcome to
//! [`crate::call_audio::runtime`], which tells the listener, the module and
//! everyone watching the channel.

use axum::Router;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::dock::manifest::call_audio::declared_in;
use super::super::error::ApiError;
use super::super::extract::{Authed, Json, enforce};
use super::super::messages::parse_uuid;
use super::super::module_host::call_audio_approved;
use crate::call_audio::session::{Refused, Subject};
use crate::call_audio::{CallAudioView, Outcome, RequestError, runtime};
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{InstalledModule, now_ms};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/channels/{channel_id}/voice/call-audio",
            get(show).post(ask).delete(stop),
        )
        .route(
            "/channels/{channel_id}/voice/call-audio/consent",
            put(consent),
        )
}

#[derive(Serialize)]
struct StartableDto {
    module_id: String,
    module_name: String,
    purpose: String,
    keeps: String,
}

#[derive(Serialize)]
struct CallAudioDto {
    session: Option<CallAudioView>,
    /// The modules this caller may start here; empty while a session is on.
    startable: Vec<StartableDto>,
}

#[derive(Deserialize)]
struct AskRequest {
    module_id: String,
}

#[derive(Deserialize)]
struct ConsentRequest {
    allow: bool,
}

async fn voice_channel(state: &AppState, user: UserId, raw: &str) -> Result<ChannelId, ApiError> {
    let id = ChannelId(parse_uuid(raw)?);
    let wanted = Permissions::VIEW_CHANNEL.union(Permissions::CONNECT);
    if !state
        .store
        .permissions_in_channel(user, id)
        .await?
        .contains(wanted)
    {
        return Err(ApiError::Forbidden);
    }
    let is_voice = state
        .store
        .channel(id)
        .await?
        .is_some_and(|c| c.kind == "voice" && c.parent_message_id.is_none());
    if !is_voice {
        return Err(ApiError::NotFound("voice channel not found"));
    }
    Ok(id)
}

async fn show(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(channel): Path<String>,
) -> Result<Json<CallAudioDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    let channel = voice_channel(&state, ctx.user_id, &channel).await?;
    let mut session = state.call_audio.view(channel);
    if let Some(view) = session.as_mut() {
        view.hide_hidden(&state.store, &state.hub, ctx.user_id)
            .await;
    }
    let startable = if session.is_some() {
        Vec::new()
    } else {
        startable_for(&state, ctx.user_id, channel).await?
    };
    Ok(Json(CallAudioDto { session, startable }))
}

async fn startable_for(
    state: &AppState,
    user: UserId,
    channel: ChannelId,
) -> Result<Vec<StartableDto>, ApiError> {
    if !state.call_audio.is_ready() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for module_id in state.store.call_audio_modules_for_channel(channel).await? {
        if let Ok((_, subject)) = startable_module(state, user, &module_id).await {
            out.push(StartableDto {
                module_id: subject.module_id,
                module_name: subject.module_name,
                purpose: subject.purpose,
                keeps: subject.keeps,
            });
        }
    }
    Ok(out)
}

/// The module, if it is on, approved and its permission is held by `user`, with the words everyone is shown.
async fn startable_module(
    state: &AppState,
    user: UserId,
    module_id: &str,
) -> Result<(InstalledModule, Subject), ApiError> {
    let missing = ApiError::NotFound("module not found");
    let module = state
        .store
        .installed_module(module_id)
        .await?
        .ok_or(missing)?;
    if !module.enabled || !call_audio_approved(&module) {
        return Err(ApiError::Conflict("the module cannot hear calls"));
    }
    let manifest = state.store.module_manifest_json(module_id).await?;
    let declared = manifest
        .as_deref()
        .and_then(declared_in)
        .ok_or(ApiError::Conflict(
            "the module did not say what it does with a call",
        ))?;
    if let Some(key) = &declared.permission
        && !state
            .store
            .user_has_module_permission(user, module_id, key)
            .await?
    {
        return Err(ApiError::Forbidden);
    }
    let subject = Subject {
        module_id: module.id.clone(),
        module_name: module.name.clone(),
        purpose: declared.purpose,
        keeps: declared.keeps,
    };
    Ok((module, subject))
}

/// Who is on the call per LiveKit's own webhooks, falling back to the SFU after a restart.
async fn people_in_call(state: &AppState, channel: ChannelId) -> Vec<UserId> {
    let live = state.voice.live_state();
    let mut present = live.present(channel);
    if present.is_empty()
        && let Ok(listed) = state.voice.list_participants(channel).await
    {
        present = listed.into_iter().map(|p| p.user_id).collect();
    }
    let mut humans = Vec::new();
    for user in present {
        if !state.store.is_bot(user).await.unwrap_or(true) {
            humans.push(user);
        }
    }
    humans
}

async fn ask(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(channel): Path<String>,
    Json(req): Json<AskRequest>,
) -> Result<Json<CallAudioDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel = voice_channel(&state, ctx.user_id, &channel).await?;
    if !state.call_audio.is_enabled() {
        return Err(ApiError::NotConfigured(
            "this server has no call audio listener",
        ));
    }
    let people = people_in_call(&state, channel).await;
    if !people.contains(&ctx.user_id) {
        return Err(ApiError::ForbiddenBecause("join the call first"));
    }
    if !state
        .store
        .call_audio_armed(&req.module_id, channel)
        .await?
    {
        return Err(ApiError::Conflict(
            "the module is not allowed to hear this channel",
        ));
    }
    let (_, subject) = startable_module(&state, ctx.user_id, &req.module_id).await?;
    let began = state
        .call_audio
        .begin((channel, subject), ctx.user_id, &people, now_ms())
        .map_err(request_error)?;
    let view = visible_view(&state, ctx.user_id, &began).await;
    runtime::apply(&state, began).await;
    Ok(Json(CallAudioDto {
        session: Some(view),
        startable: Vec::new(),
    }))
}

async fn visible_view(state: &AppState, viewer: UserId, outcome: &Outcome) -> CallAudioView {
    let mut view = outcome.view.clone();
    view.hide_hidden(&state.store, &state.hub, viewer).await;
    view
}

fn request_error(err: RequestError) -> ApiError {
    match err {
        RequestError::Unavailable => ApiError::Unavailable,
        RequestError::Busy => ApiError::Conflict("busy: the listener is hearing other calls"),
        RequestError::AlreadyOn => ApiError::Conflict("a module is already hearing this call"),
        RequestError::TooManyPeople => ApiError::Conflict("too many people are in this call"),
        RequestError::Cooldown(ms) => ApiError::RateLimited {
            retry_after_seconds: u64::try_from(ms / 1000 + 1).unwrap_or(60),
        },
    }
}

async fn consent(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(channel): Path<String>,
    Json(req): Json<ConsentRequest>,
) -> Result<Json<CallAudioDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel = voice_channel(&state, ctx.user_id, &channel).await?;
    let outcome = state
        .call_audio
        .consent(channel, ctx.user_id, req.allow, now_ms())
        .ok_or(ApiError::NotFound("no call audio is being asked"))?
        .map_err(refused)?;
    let mut session = Some(visible_view(&state, ctx.user_id, &outcome).await);
    if outcome
        .effects
        .iter()
        .any(|e| matches!(e, crate::call_audio::session::Effect::Ended { .. }))
    {
        session = None;
    }
    runtime::apply(&state, outcome).await;
    Ok(Json(CallAudioDto {
        session,
        startable: Vec::new(),
    }))
}

fn refused(err: Refused) -> ApiError {
    match err {
        Refused::NotInCall => ApiError::ForbiddenBecause("join the call first"),
    }
}

async fn stop(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(channel): Path<String>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel = voice_channel(&state, ctx.user_id, &channel).await?;
    let outcome = state
        .call_audio
        .stop(channel, ctx.user_id, now_ms())
        .ok_or(ApiError::NotFound("no call audio is on"))?
        .map_err(refused)?;
    runtime::apply(&state, outcome).await;
    Ok(StatusCode::NO_CONTENT)
}
