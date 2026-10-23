// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Workers that run queued events as ordinary module runs on the background lane.

use std::sync::Arc;

use super::events_approved;
use super::queue::{Job, Queues};
use crate::http::AppState;
use crate::http::module_host::{scheduled_surface, surface_posting_as};
use crate::http::module_run::{RunKind, RunRequest, run_installed};
use crate::ids::UserId;
use crate::module_runtime::CapabilitySurface;
use crate::permissions::Permissions;
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
        let standing = standing(&state, &job).await;
        if let Standing::Receives(module) = &standing {
            deliver(&state, module, &job).await;
        }
        queues.finish(&job.module_id);
        match standing {
            Standing::Receives(_) => {}
            Standing::Unsubscribed => queues.clear_kind(&job.module_id, job.kind),
            Standing::Gone => queues.clear(&job.module_id),
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

/// Whether a job's module can still be sent it, read fresh since an admin can change any of it.
enum Standing {
    Receives(Box<InstalledModule>),
    /// Enabled and approved, but no longer subscribed to this kind.
    Unsubscribed,
    Gone,
}

async fn standing(state: &AppState, job: &Job) -> Standing {
    let Some(module) = state
        .store
        .installed_module(&job.module_id)
        .await
        .ok()
        .flatten()
    else {
        return Standing::Gone;
    };
    if !(module.enabled && events_approved(&module) && module.bot_user_id.is_some()) {
        return Standing::Gone;
    }
    if module.subscriptions.iter().any(|s| s == job.kind) {
        Standing::Receives(Box::new(module))
    } else {
        Standing::Unsubscribed
    }
}

/// The body was rendered when the event queued; what it shows must still be the module's to see.
async fn still_visible(state: &AppState, bot: UserId, job: &Job) -> bool {
    if let Some(channel) = job.origin.channel {
        let sees = state
            .store
            .has_permission(bot, channel, Permissions::VIEW_CHANNEL)
            .await;
        if !sees.unwrap_or(false) {
            return false;
        }
    }
    match job.origin.created_message {
        Some(message) => state
            .store
            .message(message)
            .await
            .is_ok_and(|found| found.is_some()),
        None => true,
    }
}

async fn deliver(state: &AppState, module: &InstalledModule, job: &Job) {
    let Some(bot) = module.bot_user_id else {
        return;
    };
    if !still_visible(state, bot, job).await {
        return;
    }
    let request = RunRequest {
        caller: bot,
        command: EVENT_COMMAND,
        input: &job.body,
        kind: RunKind::Background,
    };
    let surface = event_surface(state, module, bot);
    match run_installed(state, module, &request, surface).await {
        Ok(outcome) if outcome.ok => {}
        Ok(outcome) => {
            tracing::info!(module = %module.id, event = job.kind, error = %outcome.payload, "module event run failed");
        }
        Err(_) => tracing::warn!(module = %module.id, event = job.kind, "module event run refused"),
    }
}

/// Posts as the module's principal into its schedule channel when it has one, else nowhere.
fn event_surface(state: &AppState, module: &InstalledModule, bot: UserId) -> CapabilitySurface {
    match module.schedule_channel_id {
        Some(channel) => scheduled_surface(state, module, bot, channel),
        None => surface_posting_as(state, module, bot, None, true),
    }
}
