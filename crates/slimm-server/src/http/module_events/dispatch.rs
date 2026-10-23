// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Workers that run queued events as ordinary module runs on the background lane.

use std::sync::Arc;

use super::events_approved;
use super::queue::{Job, Queues};
use crate::http::AppState;
use crate::http::module_host::{scheduled_surface, surface_posting_as};
use crate::http::module_run::{RunRequest, run_installed};
use crate::module_runtime::CapabilitySurface;
use crate::store::InstalledModule;

/// The command an event run is delivered to.
pub(super) const EVENT_COMMAND: &str = "@event";

pub(super) async fn work(state: AppState, queues: Arc<Queues>) {
    loop {
        flush_drops(&state, &queues).await;
        let Some(job) = queues.take() else {
            queues.work_available().await;
            continue;
        };
        deliver(&state, &job).await;
        queues.finish(&job.module_id);
        if !still_receives(&state, &job).await {
            queues.clear(&job.module_id);
        }
    }
}

async fn flush_drops(state: &AppState, queues: &Queues) {
    for (module_id, dropped) in queues.take_dropped() {
        let dropped = i64::try_from(dropped).unwrap_or(i64::MAX);
        if let Err(err) = state
            .store
            .add_module_events_dropped(&module_id, dropped)
            .await
        {
            tracing::warn!(%err, module = %module_id, "could not count dropped module events");
        }
    }
}

/// Whether the module is still enabled, approved and subscribed; read fresh, since an admin can change any of it.
async fn receiver(state: &AppState, job: &Job) -> Option<InstalledModule> {
    let module = state.store.installed_module(&job.module_id).await.ok()??;
    let subscribed = module.subscriptions.iter().any(|s| s == job.kind);
    (module.enabled && events_approved(&module) && subscribed && module.bot_user_id.is_some())
        .then_some(module)
}

async fn still_receives(state: &AppState, job: &Job) -> bool {
    receiver(state, job).await.is_some()
}

async fn deliver(state: &AppState, job: &Job) {
    let Some(module) = receiver(state, job).await else {
        return;
    };
    let Some(bot) = module.bot_user_id else {
        return;
    };
    let request = RunRequest {
        caller: bot,
        command: EVENT_COMMAND,
        input: &job.body,
        scheduled: true,
    };
    let surface = event_surface(state, &module, bot);
    match run_installed(state, &module, &request, surface).await {
        Ok(outcome) if outcome.ok => {}
        Ok(outcome) => {
            tracing::info!(module = %module.id, event = job.kind, error = %outcome.payload, "module event run failed");
        }
        Err(_) => tracing::warn!(module = %module.id, event = job.kind, "module event run refused"),
    }
}

/// Posts as the module's principal into its schedule channel when it has one, else nowhere.
fn event_surface(
    state: &AppState,
    module: &InstalledModule,
    bot: crate::ids::UserId,
) -> CapabilitySurface {
    match module.schedule_channel_id {
        Some(channel) => scheduled_surface(state, module, bot, channel),
        None => surface_posting_as(state, module, bot, None, true),
    }
}
