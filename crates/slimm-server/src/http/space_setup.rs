// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /space/setup` and `POST /space/setup/complete`: what this machine has
//! and can carry, and whether the admin who claimed the deployment has
//! finished the first-run setup the client offers them once.

use axum::Router;
use axum::extract::State;
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, post};
use serde::Serialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_manage_server};
use crate::capacity::{self, Hardware, host};
use crate::hub::memory_limit_bytes;
use crate::ids::UserId;
use crate::ratelimit::Class;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/setup", get(read))
        .route("/space/setup/complete", post(complete))
}

#[derive(Serialize)]
struct EstimateDto {
    /// The first thing to run out: `connections`, `memory` or `processor`.
    binding: &'static str,
    connection_limit: u32,
    members_min: u32,
    members_max: u32,
    /// People in one call if LiveKit shares this machine; absent when voice is off.
    voice_min: Option<u32>,
    voice_max: Option<u32>,
}

#[derive(Serialize)]
struct CapacityDto {
    cores: u32,
    memory_total_bytes: Option<u64>,
    /// The cgroup limit, absent when the server is not limited.
    memory_limit_bytes: Option<u64>,
    disk_free_bytes: Option<u64>,
    disk_total_bytes: Option<u64>,
    voice_configured: bool,
    estimate: EstimateDto,
}

#[derive(Serialize)]
struct SpaceSetupDto {
    /// Whether the caller is the admin whose registration claimed the deployment.
    claimed_by_me: bool,
    completed: bool,
    capacity: CapacityDto,
}

fn capacity_dto(state: &AppState) -> CapacityDto {
    let cores = host::cores();
    let total = host::total_memory_bytes();
    let limit = memory_limit_bytes();
    let usable = match (total, limit) {
        (Some(total), Some(limit)) => total.min(limit),
        (Some(bytes), None) | (None, Some(bytes)) => bytes,
        (None, None) => 0,
    };
    let voice_configured = state.voice.is_enabled();
    let estimate = capacity::estimate(
        Hardware {
            cores,
            memory_bytes: usable,
        },
        voice_configured,
    );
    let disk = host::disk_bytes(state.media.volume_dir());
    CapacityDto {
        cores: cores.round() as u32,
        memory_total_bytes: total,
        memory_limit_bytes: limit,
        disk_free_bytes: disk.map(|(free, _)| free),
        disk_total_bytes: disk.map(|(_, total)| total),
        voice_configured,
        estimate: EstimateDto {
            binding: estimate.binding.as_str(),
            connection_limit: estimate.connection_limit,
            members_min: estimate.members_min,
            members_max: estimate.members_max,
            voice_min: estimate.voice_min,
            voice_max: estimate.voice_max,
        },
    }
}

fn is_claimer(claimed_by: Option<UserId>, caller: UserId) -> bool {
    claimed_by == Some(caller)
}

async fn read(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<SpaceSetupDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    let setup = state.store.space_setup().await?;
    Ok(Json(SpaceSetupDto {
        claimed_by_me: is_claimer(setup.claimed_by, ctx.user_id),
        completed: setup.done_at.is_some(),
        capacity: capacity_dto(&state),
    }))
}

/// Idempotent, and only the claiming admin may close the offer: another
/// admin finishing it would take the one-time setup away from them.
async fn complete(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let setup = state.store.space_setup().await?;
    if !is_claimer(setup.claimed_by, ctx.user_id) {
        return Err(ApiError::ForbiddenBecause(
            "only the admin who set this server up can finish its setup",
        ));
    }
    state.store.complete_space_setup().await?;
    Ok(StatusCode::NO_CONTENT)
}
