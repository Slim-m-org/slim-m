// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Telling an account's other devices that a channel was read, so a phone that is not running
//! takes its delivered notifications down and corrects its badge.
//!
//! The envelope names the channel and nothing else: no sender, no text, no count.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Serialize;

use crate::ids::{ChannelId, DeviceId, UserId};
use crate::store::{Store, now_ms};

use super::envelope::{DOMAIN, ENVELOPE_VERSION, PushKind};
use super::sealing::{TokenSlot, seal_to};
use super::{Enabled, dispatch};

/// How long reads of one channel by one device collapse into a single push.
pub(super) const DEFAULT_WINDOW: Duration = Duration::from_secs(3);

/// A read in flight, keyed by whose it is, where, and which device did the reading.
type Key = (UserId, ChannelId, DeviceId);

/// Trailing coalescing: the first read opens a window, and the push goes out when it closes.
pub(super) struct ReadClearGate {
    pub(super) window: Duration,
    pending: Mutex<HashSet<Key>>,
}

impl ReadClearGate {
    pub(super) fn new(window: Duration) -> Self {
        Self {
            window,
            pending: Mutex::new(HashSet::new()),
        }
    }

    /// True when this read opened a window, false when one is already collecting it.
    pub(super) fn open(&self, key: Key) -> bool {
        self.lock().insert(key)
    }

    pub(super) fn close(&self, key: &Key) {
        self.lock().remove(key);
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashSet<Key>> {
        self.pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[derive(Serialize)]
struct ReadEnvelope {
    domain: &'static str,
    version: u8,
    kind: PushKind,
    channel_id: String,
    sent_at: i64,
}

/// Waits out the window, then sends a `read` for `channel_id` to every device of `user_id`
/// except `origin`, the one that did the reading.
pub(super) async fn deliver(
    enabled: Arc<Enabled>,
    gate: Arc<ReadClearGate>,
    store: Store,
    key: Key,
) {
    tokio::time::sleep(gate.window).await;
    gate.close(&key);
    let (user_id, channel_id, origin) = key;
    let targets = match store.push_targets(&[user_id]).await {
        Ok(targets) => targets,
        Err(err) => {
            tracing::warn!(error = %err, %channel_id, "push: failed to load a read's push targets");
            return;
        }
    };
    let envelope = ReadEnvelope {
        domain: DOMAIN,
        version: ENVELOPE_VERSION,
        kind: PushKind::Read,
        channel_id: channel_id.to_string(),
        sent_at: now_ms(),
    };
    let Ok(plaintext) = serde_json::to_vec(&envelope) else {
        tracing::error!("push: read envelope failed to serialize");
        return;
    };
    let messages: Vec<_> = targets
        .iter()
        .filter(|target| target.device_id != origin)
        .filter_map(|target| seal_to(target, TokenSlot::Push, PushKind::Read, &plaintext))
        .collect();
    if messages.is_empty() {
        return;
    }
    dispatch::send_and_prune(&enabled, &store, &messages, "read").await;
}
