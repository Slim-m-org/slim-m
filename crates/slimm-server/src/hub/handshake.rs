// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bounds on sockets: before they prove who they are, and how long a proven one may stay silent.

use std::collections::HashMap;
use std::net::Ipv6Addr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::Hub;
use crate::ids::UserId;

/// How many unauthenticated sockets one address may hold open at once. A real client has one,
/// briefly, so this only ever refuses a flood.
const MAX_PENDING_PER_ADDRESS: usize = 8;

/// How many unauthenticated sockets one IPv6 /48 may hold, as a multiple of the per-address share.
const PREFIX_SHARE: usize = 4;

/// The part of the connection ceiling unauthenticated sockets may hold between them, as a divisor.
const PENDING_POOL_DIVISOR: usize = 4;

/// How many live sockets one human account may hold.
const MAX_SOCKETS_PER_USER: usize = 16;

/// How many live sockets one bot or connector account may hold.
const MAX_SOCKETS_PER_BOT: usize = 64;

/// How long a freshly connected socket has to send its `hello` before it is dropped.
const AUTH_DEADLINE: Duration = Duration::from_secs(10);

/// How long an authenticated socket may send nothing at all before it is treated as dead.
/// The client pings every 20 s, so this tolerates a throttled background tab with room to spare.
const LIVENESS_DEADLINE: Duration = Duration::from_secs(90);

/// Live pre-auth sockets, counted per address key, per wider network prefix, and in all.
#[derive(Default)]
struct Pending {
    by_key: HashMap<String, usize>,
    by_prefix: HashMap<String, usize>,
    total: usize,
}

impl Pending {
    fn release(&mut self, key: &str) {
        decrement(&mut self.by_key, key);
        decrement(&mut self.by_prefix, &prefix_of(key));
        self.total = self.total.saturating_sub(1);
    }
}

fn decrement(counts: &mut HashMap<String, usize>, key: &str) {
    if let Some(count) = counts.get_mut(key) {
        *count -= 1;
        if *count == 0 {
            counts.remove(key);
        }
    }
}

/// The key an IPv6 `/64` address key rolls up to (its `/48`); any other key is its own prefix.
fn prefix_of(key: &str) -> String {
    key.strip_prefix("ip:")
        .and_then(|rest| rest.strip_suffix("/64"))
        .and_then(|addr| addr.parse::<Ipv6Addr>().ok())
        .map(|addr| {
            let masked = u128::from(addr) & !((1u128 << 80) - 1);
            format!("ip:{}/48", Ipv6Addr::from(masked))
        })
        .unwrap_or_else(|| key.to_owned())
}

/// The limits on pre-auth sockets, and the live count of them.
#[derive(Clone)]
pub(super) struct Handshake {
    pending: Arc<Mutex<Pending>>,
    sockets: Arc<Mutex<HashMap<UserId, usize>>>,
    per_address: usize,
    deadline: Duration,
    liveness: Duration,
}

impl Handshake {
    pub(super) fn new() -> Self {
        Self {
            pending: Arc::default(),
            sockets: Arc::default(),
            per_address: MAX_PENDING_PER_ADDRESS,
            deadline: AUTH_DEADLINE,
            liveness: LIVENESS_DEADLINE,
        }
    }
}

/// One address's claim on a pre-auth socket; dropping it frees the claim.
pub struct PendingGuard {
    pending: Arc<Mutex<Pending>>,
    key: String,
}

impl PendingGuard {
    /// The address key this claim was made under.
    pub fn address(&self) -> &str {
        &self.key
    }
}

impl Drop for PendingGuard {
    fn drop(&mut self) {
        let mut pending = self
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        pending.release(&self.key);
    }
}

/// One authenticated socket's claim on its account's share; dropping it frees the claim.
pub struct UserSocketGuard {
    sockets: Arc<Mutex<HashMap<UserId, usize>>>,
    user_id: UserId,
}

impl Drop for UserSocketGuard {
    fn drop(&mut self) {
        let mut sockets = self
            .sockets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(count) = sockets.get_mut(&self.user_id) {
            *count -= 1;
            if *count == 0 {
                sockets.remove(&self.user_id);
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

    /// Builds a hub that drops a silent authenticated socket after `deadline`, so a test need not wait out the real one.
    pub fn with_liveness_deadline(deadline: Duration) -> Self {
        Self {
            handshake: Handshake {
                liveness: deadline,
                ..Handshake::new()
            },
            ..Self::new()
        }
    }

    /// Claims one of `key`'s pre-auth socket slots, or `None` if it, its network prefix or the
    /// shared pre-auth pool is holding its share.
    pub fn try_hold_pending(&self, key: &str) -> Option<PendingGuard> {
        let prefix = prefix_of(key);
        let pool = (self.max_connections / PENDING_POOL_DIVISOR).max(1);
        let mut pending = self
            .handshake
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let over_key = pending.by_key.get(key).copied().unwrap_or(0) >= self.handshake.per_address;
        let over_prefix = pending.by_prefix.get(&prefix).copied().unwrap_or(0)
            >= self.handshake.per_address * PREFIX_SHARE;
        if over_key || over_prefix || pending.total >= pool {
            return None;
        }
        *pending.by_key.entry(key.to_owned()).or_insert(0) += 1;
        *pending.by_prefix.entry(prefix).or_insert(0) += 1;
        pending.total += 1;
        Some(PendingGuard {
            pending: self.handshake.pending.clone(),
            key: key.to_owned(),
        })
    }

    /// Claims one of an authenticated account's socket slots, or `None` if it holds its whole share.
    pub fn try_hold_user_socket(&self, user_id: UserId, bot: bool) -> Option<UserSocketGuard> {
        let cap = if bot {
            MAX_SOCKETS_PER_BOT
        } else {
            MAX_SOCKETS_PER_USER
        };
        let mut sockets = self
            .handshake
            .sockets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let count = sockets.entry(user_id).or_insert(0);
        if *count >= cap {
            return None;
        }
        *count += 1;
        Some(UserSocketGuard {
            sockets: self.handshake.sockets.clone(),
            user_id,
        })
    }

    /// How long a new socket has to send its `hello`.
    pub fn auth_deadline(&self) -> Duration {
        self.handshake.deadline
    }

    /// How long an authenticated socket may send nothing before it is closed.
    pub fn liveness_deadline(&self) -> Duration {
        self.handshake.liveness
    }
}
