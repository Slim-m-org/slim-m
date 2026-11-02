// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A shared scene that asks to be redrawn (`"refresh_ms"`, docs/modules/
//! building-modules.md): the host runs the surface's command again with the
//! action `refresh`, stores and broadcasts the new frame, and repeats while the
//! module keeps asking. Without this a timer on a shared scene moves only when
//! someone presses a button.
//!
//! A chain stops when a frame does not ask again, when the module fails or goes
//! private, or half an hour after the last person pressed something.

use std::time::Duration;

use serde_json::Value;

use super::AppState;
use super::code_runs::{held_input, is_private_scene, publish_run, stored_payload};
use super::module_commands::execute_command;
use super::surface_lock::lock_surface;
use crate::ids::MessageId;
use crate::store::now_ms;

const MIN_REFRESH_MS: i64 = 2_000;
const MAX_REFRESH_MS: i64 = 60_000;
const WINDOW_MS: i64 = 30 * 60_000;
const SWEEP_EVERY: Duration = Duration::from_secs(1);
const BATCH: i64 = 16;

/// The redraw interval a scene asks for, kept inside what the host allows.
pub(super) fn requested_ms(scene: &str) -> Option<i64> {
    if !scene.contains("\"refresh_ms\"") {
        return None;
    }
    let scene: Value = serde_json::from_str(scene).ok()?;
    if scene.get("$slim")?.as_str() != Some("scene/1") {
        return None;
    }
    let asked = scene.get("refresh_ms")?.as_i64()?;
    Some(asked.clamp(MIN_REFRESH_MS, MAX_REFRESH_MS))
}

/// Queues the next redraw. `until_at` is the end of a running chain; `None`
/// means a person just acted, which starts a fresh window.
pub(super) async fn note(state: &AppState, message: MessageId, ms: i64, until_at: Option<i64>) {
    let now = now_ms();
    let (until, extend) = match until_at {
        Some(until) => (until, false),
        None => (now + WINDOW_MS, true),
    };
    if let Err(err) = state
        .store
        .schedule_scene_refresh(message, (now + ms, until), extend)
        .await
    {
        tracing::warn!(%err, "could not queue a scene refresh");
    }
}

pub(super) async fn stop(state: &AppState, message: MessageId) {
    if let Err(err) = state.store.clear_scene_refresh(message).await {
        tracing::warn!(%err, "could not clear a scene refresh");
    }
}

pub(crate) fn spawn_sweep(state: AppState) {
    crate::sweeps::spawn_sweep(SWEEP_EVERY, move || {
        let state = state.clone();
        async move {
            if let Err(err) = run_due(&state, now_ms()).await {
                tracing::warn!(error = %err, "scene refresh sweep failed");
            }
        }
    });
}

/// Redraws every scene whose time has come, one at a time; returns how many were redrawn.
pub async fn run_due(state: &AppState, now: i64) -> anyhow::Result<usize> {
    let mut redrawn = 0;
    for (message, until_at) in state.store.due_scene_refreshes(now, BATCH).await? {
        if now >= until_at {
            stop(state, message).await;
            continue;
        }
        match redraw(state, message).await {
            Some(ms) => {
                note(state, message, ms, Some(until_at)).await;
                redrawn += 1;
            }
            None => stop(state, message).await,
        }
    }
    Ok(redrawn)
}

/// Runs the surface once; the interval to ask again after, or `None` to stop.
async fn redraw(state: &AppState, message_id: MessageId) -> Option<i64> {
    let surface = state
        .store
        .app_surface_for_message(message_id)
        .await
        .ok()??;
    let message = state.store.message(message_id).await.ok()??;
    let _turn = lock_surface(message_id).await;
    let last = state
        .store
        .code_runs_for_messages(&[message_id])
        .await
        .ok()?
        .into_iter()
        .flat_map(|(_, runs)| runs)
        .find(|run| run.block_index == 0 && run.ok)?;
    let person = last.ran_by?;
    let input = held_input(state, message_id, r#"{"action":"refresh"}"#)
        .await
        .ok()?;
    let outcome = execute_command(
        state,
        person,
        &surface.module_id,
        &surface.command,
        &input,
        message.channel_id,
    )
    .await
    .ok()?;
    let (ok, stored) = stored_payload(false, outcome);
    if !ok || is_private_scene(&stored) {
        return None;
    }
    publish_run(
        state,
        (message_id, message.channel_id),
        (&surface.module_id, &surface.command),
        (ok, &stored, person),
        0,
    )
    .await
    .ok()?;
    requested_ms(&stored)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scene(extra: &str) -> String {
        format!(r#"{{"$slim":"scene/1","ops":[]{extra}}}"#)
    }

    #[test]
    fn a_scene_without_refresh_ms_does_not_ask() {
        assert_eq!(requested_ms(&scene("")), None);
        assert_eq!(requested_ms("not json \"refresh_ms\""), None);
    }

    #[test]
    fn the_interval_is_kept_inside_the_hosts_bounds() {
        assert_eq!(
            requested_ms(&scene(r#","refresh_ms":10"#)),
            Some(MIN_REFRESH_MS)
        );
        assert_eq!(requested_ms(&scene(r#","refresh_ms":5000"#)), Some(5000));
        assert_eq!(
            requested_ms(&scene(r#","refresh_ms":99999999"#)),
            Some(MAX_REFRESH_MS)
        );
        assert_eq!(requested_ms(&scene(r#","refresh_ms":"soon""#)), None);
    }

    #[test]
    fn only_a_scene_can_ask() {
        assert_eq!(requested_ms(r#"{"refresh_ms":5000}"#), None);
    }
}
