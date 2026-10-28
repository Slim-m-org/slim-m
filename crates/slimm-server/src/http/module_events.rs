// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pushed events (decision 0091): a consumer subscribes to the hub, turns what
//! happened into the module-facing shapes, and queues each for every module
//! that subscribed, was approved the `events` capability and may see where it
//! happened. Workers then run the queue as `@event` runs on the background
//! lane, one event of a module at a time.

mod build;
mod depths;
mod dispatch;
mod queue;
mod wire;

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use tokio::sync::broadcast::error::RecvError;
use tokio::task::JoinHandle;

use self::build::{ReactionTally, build, classify};
pub(super) use self::depths::QueueDepths;
use self::queue::{Origin, QUEUE_CAPACITY, Queues};
use self::wire::ModuleEvent;
use super::AppState;
use crate::hub::Event;
use crate::permissions::Permissions;
use crate::store::{InstalledModule, now_ms};

/// Concurrent event runs; the background lane has the same number of slots.
const WORKERS: usize = 2;

/// Whether an admin approved `module` to be sent events.
pub(crate) fn events_approved(module: &InstalledModule) -> bool {
    super::module_host::effective_capabilities(module)
        .iter()
        .any(|c| c == "events")
}

/// The running consumer, for a test or a metric to read.
pub struct EventConsumer {
    /// Hub events the consumer missed because it fell behind; it carried on.
    pub lagged: Arc<AtomicU64>,
    _tasks: Vec<JoinHandle<()>>,
}

pub fn spawn_module_events(state: AppState) -> EventConsumer {
    let queues = Queues::with_depths(QUEUE_CAPACITY, state.dock.queue_depths());
    let lagged = Arc::new(AtomicU64::new(0));
    // Subscribed before the task starts, so nothing published after this call is missed.
    let events = state.hub.subscribe();
    let mut tasks = vec![tokio::spawn(consume(
        (state.clone(), queues.clone(), lagged.clone()),
        events,
    ))];
    for _ in 0..WORKERS {
        tasks.push(tokio::spawn(dispatch::work(state.clone(), queues.clone())));
    }
    EventConsumer {
        lagged,
        _tasks: tasks,
    }
}

async fn consume(
    (state, queues, lagged): (AppState, Arc<Queues>, Arc<AtomicU64>),
    mut events: tokio::sync::broadcast::Receiver<Event>,
) {
    let tally = ReactionTally::default();
    loop {
        match events.recv().await {
            Ok(event) => {
                if let Err(err) = enqueue(&state, &queues, &tally, event).await {
                    tracing::warn!(%err, "could not queue a module event");
                }
            }
            Err(RecvError::Lagged(missed)) => {
                lagged.fetch_add(missed, Ordering::Relaxed);
                tracing::warn!(missed, "module event consumer fell behind");
            }
            Err(RecvError::Closed) => return,
        }
    }
}

async fn enqueue(
    state: &AppState,
    queues: &Queues,
    tally: &ReactionTally,
    event: Event,
) -> anyhow::Result<()> {
    let event = event.into_inner();
    let Some(kind) = classify(&event) else {
        return Ok(());
    };
    let candidates = state.store.module_event_candidates(kind.name).await?;
    if candidates.is_empty() {
        return Ok(());
    }
    if let Some(channel) = kind.channel
        && !is_server_channel(state, channel).await?
    {
        return Ok(());
    }
    let mut receivers = Vec::new();
    for candidate in candidates {
        let sees = match kind.channel {
            Some(channel) => {
                state
                    .store
                    .has_permission(candidate.bot_user_id, channel, Permissions::VIEW_CHANNEL)
                    .await?
            }
            None => true,
        };
        if sees {
            receivers.push((candidate.module_id, candidate.bot_user_id));
        }
    }
    if receivers.is_empty() {
        return Ok(());
    }
    for built in build(&state.store, &event, tally, now_ms()).await? {
        let body: Arc<str> = serde_json::to_string(&ModuleEvent {
            event: kind.name,
            id: built.id,
            at_ms: built.at_ms,
            data: built.data,
        })?
        .into();
        let origin = Origin {
            channel: kind.channel,
            created_message: built.created.map(|(message, _)| message),
        };
        for (module_id, bot) in &receivers {
            let own = built
                .created
                .is_some_and(|(_, author)| author == Some(*bot));
            if !own {
                queues.push(module_id, (kind.name, origin), body.clone());
            }
        }
    }
    Ok(())
}

/// Direct messages are never delivered, and a channel that is gone has nothing to show.
async fn is_server_channel(
    state: &AppState,
    channel: crate::ids::ChannelId,
) -> anyhow::Result<bool> {
    Ok(state
        .store
        .channel(channel)
        .await?
        .is_some_and(|c| c.kind != crate::store::DM_CHANNEL_KIND))
}
