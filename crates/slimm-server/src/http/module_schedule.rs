// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `schedule` capability (owner decision 2026-10-14): the host runs a
//! module's declared commands on their intervals with nobody invoking them.
//!
//! A scheduled run needs three things an admin gave: `schedule` approved, a
//! channel chosen with `PUT /space/dock/modules/{id}/schedule-channel`, and
//! the module enabled. It runs as the module's own principal, which may post
//! only in that channel, and its posts carry the module's name. Run times are
//! stored, so a restart does not reset a long interval.

use axum::Router;
use axum::extract::{Path, State};
use axum::http::request::Parts;
use axum::routing::put;
use serde::Deserialize;
use uuid::Uuid;

use super::AppState;
use super::dock::wire::InstalledModuleDto;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_manage_server};
use super::module_host::{schedule_approved, scheduled_surface};
use super::module_run::run_installed;
use crate::ids::ChannelId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{InstalledModule, ModuleSchedule};

pub fn routes() -> Router<AppState> {
    Router::new().route(
        "/space/dock/modules/{id}/schedule-channel",
        put(set_schedule_channel),
    )
}

#[derive(Deserialize)]
struct ScheduleChannelRequest {
    channel_id: Option<String>,
}

/// Lets the module's principal post in the chosen channel and nowhere it was
/// let before; `null` stops scheduled runs.
async fn set_schedule_channel(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
    Json(req): Json<ScheduleChannelRequest>,
) -> Result<Json<InstalledModuleDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let module = state
        .store
        .installed_module(&id)
        .await?
        .ok_or(ApiError::NotFound("module not installed"))?;
    let bot = module
        .bot_user_id
        .filter(|_| schedule_approved(&module))
        .ok_or(ApiError::Conflict("the module's schedule is not approved"))?;
    let channel = match req.channel_id.as_deref() {
        None => None,
        Some(raw) => Some(text_channel(&state, raw).await?),
    };
    let post = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    if let Some(old) = module
        .schedule_channel_id
        .filter(|old| Some(*old) != channel)
    {
        state.store.delete_member_overwrite(old, bot).await?;
    }
    if let Some(new) = channel {
        state
            .store
            .set_member_overwrite(new, bot, post, Permissions::NONE)
            .await?;
    }
    state
        .store
        .set_module_schedule_channel(&id, channel)
        .await?;
    let updated = state
        .store
        .installed_module(&id)
        .await?
        .ok_or(ApiError::NotFound("module not installed"))?;
    Ok(Json(InstalledModuleDto::from(updated)))
}

async fn text_channel(state: &AppState, raw: &str) -> Result<ChannelId, ApiError> {
    let missing = ApiError::BadRequest("channel_id is not a text channel");
    let Ok(id) = Uuid::parse_str(raw).map(ChannelId) else {
        return Err(missing);
    };
    match state.store.channel(id).await? {
        Some(channel) if channel.kind == "text" && channel.parent_message_id.is_none() => Ok(id),
        _ => Err(missing),
    }
}

/// Whether `schedule` is due at `now`, given when it last ran.
pub(crate) fn is_due(schedule: &ModuleSchedule, last_run_at: Option<i64>, now: i64) -> bool {
    let every_ms = i64::from(schedule.every_minutes) * 60_000;
    last_run_at.is_none_or(|last| now - last >= every_ms)
}

/// Runs every due scheduled command once, one at a time so a busy tick
/// cannot pile module runs onto the blocking pool; returns how many ran.
pub async fn run_due(state: &AppState, now: i64) -> anyhow::Result<usize> {
    let mut ran = 0;
    for module in state.store.list_installed_modules().await? {
        let (Some(bot), Some(channel)) = (module.bot_user_id, module.schedule_channel_id) else {
            continue;
        };
        if !module.enabled || !schedule_approved(&module) {
            continue;
        }
        // A deleted principal keeps its overwrite, so this is what stops it.
        if state.store.user_profile(bot).await?.is_none() {
            continue;
        }
        let last_runs = state.store.module_schedule_runs(&module.id).await?;
        for schedule in &module.schedules {
            if !is_due(schedule, last_runs.get(&schedule.command).copied(), now) {
                continue;
            }
            // Recorded first, so a run that crashes the tick is not retried every minute.
            state
                .store
                .record_module_schedule_run(&module.id, &schedule.command, now)
                .await?;
            run_one(state, &module, bot, channel, &schedule.command).await;
            ran += 1;
        }
    }
    Ok(ran)
}

async fn run_one(
    state: &AppState,
    module: &InstalledModule,
    bot: crate::ids::UserId,
    channel: ChannelId,
    command: &str,
) {
    let surface = scheduled_surface(state, module, bot, channel);
    match run_installed(state, module, bot, command, "", surface).await {
        Ok(outcome) if outcome.ok => {}
        Ok(outcome) => {
            tracing::info!(module = %module.id, command, error = %outcome.payload, "scheduled module run failed");
        }
        Err(err) => {
            let status = axum::response::IntoResponse::into_response(err).status();
            tracing::warn!(module = %module.id, command, %status, "scheduled module run refused");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn every(minutes: u32) -> ModuleSchedule {
        ModuleSchedule {
            command: "poll".into(),
            every_minutes: minutes,
        }
    }

    #[test]
    fn a_schedule_never_run_is_due_and_then_waits_its_interval() {
        assert!(is_due(&every(15), None, 0));
        assert!(!is_due(&every(15), Some(0), 15 * 60_000 - 1));
        assert!(is_due(&every(15), Some(0), 15 * 60_000));
    }
}
