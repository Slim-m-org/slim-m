// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The long poll on the canvas op feed: `wait` seconds of parked read between a caller's cursor and the next op.
//!
//! A parked read holds no database connection and no rate-limit state; it listens on the hub's durable stream and re-reads only when a canvas op for its channel goes by.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex, PoisonError};
use std::time::Duration;

use tokio::sync::broadcast::{Receiver, error::RecvError};
use tokio::time::Instant;

use super::super::error::ApiError;
use crate::hub::{CanvasEvent, Event};
use crate::ids::{ChannelId, UserId};

/// Kept under the router's 30 second request timeout so the answer is never a 504.
pub(super) const MAX_WAIT_SECS: u64 = 25;
const MAX_WAITS_PER_USER: usize = 4;
/// Parked reads share the router's in-flight request slots, so they get a fraction of them.
const MAX_WAITS_TOTAL: usize = 256;

#[derive(Default)]
struct Waits {
    total: usize,
    by_user: HashMap<UserId, usize>,
}

static WAITS: LazyLock<Mutex<Waits>> = LazyLock::new(Mutex::default);

/// One parked read's claim on its user's allowance, released on drop.
pub(super) struct WaitSlot(UserId);

impl WaitSlot {
    pub(super) fn acquire(user: UserId) -> Result<Self, ApiError> {
        let mut waits = WAITS.lock().unwrap_or_else(PoisonError::into_inner);
        if waits.total >= MAX_WAITS_TOTAL {
            return Err(ApiError::TooManyRequests);
        }
        let held = waits.by_user.entry(user).or_default();
        if *held >= MAX_WAITS_PER_USER {
            return Err(ApiError::TooManyRequests);
        }
        *held += 1;
        waits.total += 1;
        Ok(Self(user))
    }
}

impl Drop for WaitSlot {
    fn drop(&mut self) {
        let mut waits = WAITS.lock().unwrap_or_else(PoisonError::into_inner);
        waits.total = waits.total.saturating_sub(1);
        if let Some(held) = waits.by_user.get_mut(&self.0) {
            *held -= 1;
            if *held == 0 {
                waits.by_user.remove(&self.0);
            }
        }
    }
}

/// The requested wait, clamped to what a request may hold.
pub(super) fn clamp_wait(requested: Option<u64>) -> Duration {
    Duration::from_secs(requested.unwrap_or(0).min(MAX_WAIT_SECS))
}

/// The channel of a canvas event that is one op of the feed.
fn op_channel(event: &Event) -> Option<ChannelId> {
    let Event::Canvas(event) = event else {
        return None;
    };
    match event {
        CanvasEvent::ObjectPlaced { channel_id, .. }
        | CanvasEvent::ObjectsRemoved { channel_id, .. }
        | CanvasEvent::Cleared { channel_id, .. }
        | CanvasEvent::ObjectsRestored { channel_id, .. }
        | CanvasEvent::ObjectMoved { channel_id, .. }
        | CanvasEvent::ObjectReordered { channel_id, .. }
        | CanvasEvent::ObjectEdited { channel_id, .. } => Some(*channel_id),
        _ => None,
    }
}

/// Parks until an op of this channel goes by, or the deadline; true means read the feed again.
///
/// A receiver that lagged missed events it cannot name, so it too answers true.
pub(super) async fn op_arrived(
    events: &mut Receiver<Event>,
    channel_id: ChannelId,
    deadline: Instant,
) -> bool {
    loop {
        match tokio::time::timeout_at(deadline, events.recv()).await {
            Err(_) | Ok(Err(RecvError::Closed)) => return false,
            Ok(Err(RecvError::Lagged(_))) => return true,
            Ok(Ok(event)) if op_channel(&event) == Some(channel_id) => return true,
            Ok(Ok(_)) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_wait_is_clamped_and_defaults_to_none() {
        assert_eq!(clamp_wait(None), Duration::ZERO);
        assert_eq!(clamp_wait(Some(7)), Duration::from_secs(7));
        assert_eq!(clamp_wait(Some(9999)), Duration::from_secs(MAX_WAIT_SECS));
    }
}
