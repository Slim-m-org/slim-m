// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Publishes who started or stopped viewing a board, batched.

use std::time::Duration;

use super::spawn_sweep;
use crate::hub::{CanvasEvent, Event, Hub};

/// How often marked viewer pairs are turned into frames; a toggle storm inside one tick costs one frame per pair.
pub const VIEWER_FLUSH_INTERVAL: Duration = Duration::from_millis(500);

/// Runs the viewer flush in the background.
pub fn spawn_canvas_viewer_flush(hub: Hub) {
    spawn_sweep(VIEWER_FLUSH_INTERVAL, move || {
        let hub = hub.clone();
        async move { flush_canvas_viewers(&hub) }
    });
}

/// One flush pass: publishes each pair whose shown state moved since the last pass.
pub fn flush_canvas_viewers(hub: &Hub) {
    let presence = hub.presence();
    for change in hub.canvas_viewers().flush(|user| presence.visibility(user)) {
        hub.publish(Event::Canvas(CanvasEvent::ViewerChanged {
            channel_id: change.channel_id,
            user_id: change.user_id,
            viewing: change.viewing,
        }));
    }
}
