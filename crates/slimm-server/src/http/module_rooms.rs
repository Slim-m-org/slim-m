// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared room state for modules (decision 0131): a small state the host keeps
//! per module in a call or a text channel. Participants send inputs, the host
//! runs the module's `@room` on them one at a time in the order they arrived,
//! and everyone who can view the channel gets each state the module answers.
//!
//! Memory only: a restart, the call ending, the channel going, the module going
//! off or a day without input drops the room.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::request::Parts;
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::messages::parse_uuid;
use super::module_commands::CommandOutcome;
use super::module_host::effective_capabilities;
use crate::hub::RoomJson;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::InstalledModule;

mod contract;
mod lifecycle;
mod registry;
mod turn;

pub(crate) use self::contract::RoomKind;
pub use self::lifecycle::end_idle;
pub(crate) use self::lifecycle::{end_call, end_channel, end_module, spawn_sweep};
pub(crate) use self::registry::Rooms;
use self::turn::{Outcome, Place};

/// The host capability a module needs to keep room state.
pub(crate) const ROOM_STATE: &str = "room.state";
/// The manifest slot that puts a module's room scene on a call's stage (decision 0133).
pub(crate) const CALL_SCENE: &str = "call.scene";
const BODY_LIMIT: usize = 4 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/module-rooms", get(list))
        .route(
            "/channels/{channel_id}/module-rooms/{module_id}/inputs",
            post(send_input),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct RoomDto {
    module_id: String,
    seq: u64,
    state: Option<RoomJson>,
    #[serde(skip_serializing_if = "Option::is_none")]
    scene: Option<RoomJson>,
    updated_at_ms: i64,
}

/// A module that offers a scene on a call's stage (decision 0133).
#[derive(Serialize)]
struct CallSceneDto {
    module_id: String,
    name: String,
    title: String,
}

#[derive(Serialize)]
struct RoomsDto {
    rooms: Vec<RoomDto>,
    /// Only for a voice channel; empty in a text channel.
    call_scenes: Vec<CallSceneDto>,
}

#[derive(Deserialize)]
struct InputRequest {
    input: String,
}

#[derive(Serialize)]
struct InputResultDto {
    /// Whether the module took the input: a new state, or the room ended.
    applied: bool,
    seq: u64,
    /// The room's state now; null when it holds none or has ended.
    state: Option<RoomJson>,
    #[serde(skip_serializing_if = "Option::is_none")]
    scene: Option<RoomJson>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

/// A reply that answered `ok` but breaks `room/1` is the module's failure, not a state.
pub(crate) fn held_to_contract(outcome: CommandOutcome) -> CommandOutcome {
    match outcome.ok.then(|| contract::answer(&outcome.payload)) {
        Some(Err(why)) => CommandOutcome::host_failure(why),
        _ => outcome,
    }
}

/// Whether an admin approved `module` to keep room state.
pub(crate) fn room_state_approved(module: &InstalledModule) -> bool {
    effective_capabilities(module)
        .iter()
        .any(|c| c == ROOM_STATE)
}

/// The room `raw` names, for someone who may view it. A DM is never a room.
async fn place(
    state: &AppState,
    user: UserId,
    raw: &str,
) -> Result<(Place, Permissions), ApiError> {
    let channel = ChannelId(parse_uuid(raw)?);
    // Checked before the kind, so a channel the caller cannot see is never told apart from none.
    let permissions = state.store.permissions_in_channel(user, channel).await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL) {
        return Err(ApiError::Forbidden);
    }
    let kind = match state.store.channel(channel).await?.map(|c| c.kind) {
        Some(kind) if kind == "voice" => RoomKind::Voice,
        Some(kind) if kind == "text" => RoomKind::Channel,
        _ => return Err(ApiError::NotFound("channel not found")),
    };
    Ok((Place { channel, kind }, permissions))
}

async fn list(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(channel): Path<String>,
) -> Result<Json<RoomsDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    let (place, _) = place(&state, ctx.user_id, &channel).await?;
    let keeping: Vec<InstalledModule> = state
        .store
        .list_installed_modules()
        .await?
        .into_iter()
        .filter(|m| m.enabled && room_state_approved(m))
        .collect();
    let rooms = state
        .dock
        .rooms()
        .in_channel(place.channel)
        .into_iter()
        .filter(|(id, _)| keeping.iter().any(|m| &m.id == id))
        .map(|(module_id, held)| RoomDto {
            module_id,
            seq: held.seq,
            state: held.state,
            scene: held.scene,
            updated_at_ms: held.touched_at,
        })
        .collect();
    let call_scenes = match place.kind {
        RoomKind::Voice => keeping.iter().filter_map(call_scene).collect(),
        RoomKind::Channel => Vec::new(),
    };
    Ok(Json(RoomsDto { rooms, call_scenes }))
}

/// The call scene `module` declares, titled by the slot or else by the module's name.
fn call_scene(module: &InstalledModule) -> Option<CallSceneDto> {
    let slot = module.slots.iter().find(|s| s.kind == CALL_SCENE)?;
    Some(CallSceneDto {
        module_id: module.id.clone(),
        name: slot.name.clone(),
        title: slot.title.clone().unwrap_or_else(|| module.name.clone()),
    })
}

async fn send_input(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path((channel, module_id)): Path<(String, String)>,
    Json(req): Json<InputRequest>,
) -> Result<Json<InputResultDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Module)?;
    if req.input.len() > contract::MAX_INPUT_BYTES {
        return Err(ApiError::BadRequest("input is longer than 1024 bytes"));
    }
    super::dock::validate_module_id(&module_id)?;
    let (place, permissions) = place(&state, ctx.user_id, &channel).await?;
    let takes_part = match place.kind {
        RoomKind::Voice => state.voice.has_heartbeat(ctx.user_id, place.channel),
        RoomKind::Channel => permissions.contains(Permissions::SEND_MESSAGES),
    };
    if !takes_part {
        return Err(ApiError::ForbiddenBecause(
            "only people taking part in this room can send it input",
        ));
    }
    state
        .limiter
        .admit(
            Class::ModuleRoomInput,
            &format!("u:{}:{module_id}:{}", ctx.user_id, place.channel),
        )
        .map_err(ApiError::from)?;
    let module = state
        .store
        .installed_module(&module_id)
        .await?
        .filter(room_state_approved)
        .ok_or(ApiError::NotFound("no module keeps room state by that id"))?;
    if !module.enabled {
        return Err(ApiError::Conflict("module is not enabled"));
    }
    let outcome = turn::take(&state, &module, place, ctx.user_id, &req.input).await?;
    Ok(Json(result_of(outcome)))
}

fn result_of(outcome: Outcome) -> InputResultDto {
    let (applied, held, reason, error) = match outcome {
        Outcome::Applied(held) => (true, held, None, None),
        Outcome::Ended => (true, registry::Held::default(), None, None),
        Outcome::Rejected(held, reason) => (false, held, Some(reason), None),
        Outcome::Failed(held, error) => (false, held, None, Some(error)),
    };
    InputResultDto {
        applied,
        seq: held.seq,
        state: held.state,
        scene: held.scene,
        reason,
        error,
    }
}
