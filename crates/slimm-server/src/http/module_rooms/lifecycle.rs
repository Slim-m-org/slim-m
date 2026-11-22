// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! When rooms end and how viewers hear of it: a module's own `end`, the call
//! finishing, the channel going, the module going off, or a day without input.

use std::sync::Arc;
use std::time::Duration;

use super::registry::{Held, RoomKey};
use crate::http::AppState;
use crate::hub::{Event, ModuleRoomChange};
use crate::ids::ChannelId;
use crate::store::now_ms;

/// A room nobody has sent an input to for this long is dropped.
pub(crate) const IDLE_MS: i64 = 24 * 60 * 60 * 1000;
const SWEEP_EVERY: Duration = Duration::from_secs(5 * 60);

/// Tells everyone who can view the channel the room's state, or that it ended with `ended`.
pub(super) fn announce(state: &AppState, key: &RoomKey, held: &Held, ended: Option<&'static str>) {
    state
        .hub
        .publish(Event::ModuleRoomChanged(Arc::new(ModuleRoomChange {
            channel_id: key.channel_id,
            module_id: key.module_id.clone(),
            seq: held.seq,
            state: if ended.is_some() {
                None
            } else {
                held.state.clone()
            },
            scene: if ended.is_some() {
                None
            } else {
                held.scene.clone()
            },
            ended,
        })));
}

/// Ends the rooms `which` picks, telling viewers of each that held a state why.
pub(super) fn end_where(
    state: &AppState,
    which: impl Fn(&RoomKey, &Held) -> bool,
    why: &'static str,
) {
    for (key, held) in state.dock.rooms().end_where(which) {
        announce(state, &key, &held, Some(why));
    }
}

/// Ends every room `module_id` keeps: it was turned off, uninstalled or installed again.
pub(crate) fn end_module(state: &AppState, module_id: &str) {
    end_where(state, |k, _| k.module_id == module_id, "module_off");
}

/// Ends every room in a call that finished.
pub(crate) fn end_call(state: &AppState, channel: ChannelId) {
    end_where(state, |k, _| k.channel_id == channel, "call_ended");
}

/// Ends every room in a channel that was deleted.
pub(crate) fn end_channel(state: &AppState, channel: ChannelId) {
    end_where(state, |k, _| k.channel_id == channel, "channel_removed");
}

/// Drops rooms that went [`IDLE_MS`] without an input; returns how many held a state.
pub fn end_idle(state: &AppState, now: i64) -> usize {
    let ended = state
        .dock
        .rooms()
        .end_where(|_, held| held.state.is_some() && now - held.touched_at >= IDLE_MS);
    for (key, held) in &ended {
        announce(state, key, held, Some("idle"));
    }
    ended.len()
}

pub(crate) fn spawn_sweep(state: AppState) {
    crate::sweeps::spawn_sweep(SWEEP_EVERY, move || {
        let state = state.clone();
        async move {
            end_idle(&state, now_ms());
        }
    });
}
