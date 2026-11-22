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
    updated_at_ms: i64,
}

#[derive(Serialize)]
struct RoomsDto {
    rooms: Vec<RoomDto>,
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
    let mut rooms = Vec::new();
    for (module_id, held) in state.dock.rooms().in_channel(place.channel) {
        let live = state.store.installed_module(&module_id).await?;
        if live.is_some_and(|m| m.enabled && room_state_approved(&m)) {
            rooms.push(RoomDto {
                module_id,
                seq: held.seq,
                state: held.state,
                updated_at_ms: held.touched_at,
            });
        }
    }
    Ok(Json(RoomsDto { rooms }))
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
        reason,
        error,
    }
}
