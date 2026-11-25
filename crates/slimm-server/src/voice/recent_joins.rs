// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! When a join token was last minted per channel, so an emptying temporary room is not
//! deleted under a member who has a token but has not yet shown up on the SFU roster.
//!
//! Ephemeral: a restart forgetting it only costs one missed grace.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::ids::ChannelId;

/// How long after a token is minted its holder may still be connecting.
pub const JOIN_GRACE_MS: i64 = 30_000;

/// Past this many channels, lapsed entries are swept on the next record.
const PRUNE_ABOVE: usize = 4_096;

#[derive(Clone, Default)]
pub struct RecentJoins {
    minted: Arc<Mutex<HashMap<ChannelId, i64>>>,
}

impl RecentJoins {
    fn lock(&self) -> MutexGuard<'_, HashMap<ChannelId, i64>> {
        self.minted
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn record(&self, channel: ChannelId, now: i64) {
        let mut minted = self.lock();
        if minted.len() >= PRUNE_ABOVE {
            minted.retain(|_, at| now - *at < JOIN_GRACE_MS);
        }
        minted.insert(channel, now);
    }

    /// Whether a token for `channel` was minted within the grace window.
    pub fn pending_at(&self, channel: ChannelId, now: i64) -> bool {
        self.lock()
            .get(&channel)
            .is_some_and(|at| now - *at < JOIN_GRACE_MS)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_token_counts_as_pending_only_inside_the_grace() {
        let joins = RecentJoins::default();
        let channel = ChannelId::generate();
        assert!(!joins.pending_at(channel, 1_000));
        joins.record(channel, 1_000);
        assert!(joins.pending_at(channel, 1_000 + JOIN_GRACE_MS - 1));
        assert!(!joins.pending_at(channel, 1_000 + JOIN_GRACE_MS));
        assert!(!joins.pending_at(ChannelId::generate(), 1_000));
    }
}
