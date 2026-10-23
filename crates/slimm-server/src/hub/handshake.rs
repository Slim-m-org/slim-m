// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bounds on sockets that have connected but not yet proven who they are.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::Hub;

/// How many unauthenticated sockets one address may hold open at once. A real client has one,
/// briefly, so this only ever refuses a flood.
const MAX_PENDING_PER_ADDRESS: usize = 8;

/// How long a freshly connected socket has to send its `hello` before it is dropped.
const AUTH_DEADLINE: Duration = Duration::from_secs(10);

/// The limits on pre-auth sockets, and the live count of them per address.
#[derive(Clone)]
pub(super) struct Handshake {
    pending: Arc<Mutex<HashMap<String, usize>>>,
    per_address: usize,
    deadline: Duration,
}

impl Handshake {
    pub(super) fn new() -> Self {
        Self {
            pending: Arc::default(),
            per_address: MAX_PENDING_PER_ADDRESS,
            deadline: AUTH_DEADLINE,
        }
    }
}

/// One address's claim on a pre-auth socket; dropping it frees the claim.
pub struct PendingGuard {
    pending: Arc<Mutex<HashMap<String, usize>>>,
    key: String,
}

impl Drop for PendingGuard {
    fn drop(&mut self) {
        let mut pending = self
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(count) = pending.get_mut(&self.key) {
            *count -= 1;
            if *count == 0 {
                pending.remove(&self.key);
            }
        }
    }
}

impl Hub {
    /// Builds a hub with non-default pre-auth limits, so a test can hit the cap or the
    /// deadline in milliseconds.
    pub fn with_handshake_limits(per_address: usize, deadline: Duration) -> Self {
        Self {
            handshake: Handshake {
                per_address,
                deadline,
                ..Handshake::new()
            },
            ..Self::new()
        }
    }

    /// Claims one of `key`'s pre-auth socket slots, or `None` if it is holding its share.
    pub fn try_hold_pending(&self, key: &str) -> Option<PendingGuard> {
        let mut pending = self
            .handshake
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let count = pending.entry(key.to_owned()).or_insert(0);
        if *count >= self.handshake.per_address {
            return None;
        }
        *count += 1;
        Some(PendingGuard {
            pending: self.handshake.pending.clone(),
            key: key.to_owned(),
        })
    }

    /// How long a new socket has to send its `hello`.
    pub fn auth_deadline(&self) -> Duration {
        self.handshake.deadline
    }
}
