// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The call each member last asked a join token for, which is the call their person chose last.
//!
//! A connection can walk back into a room without asking: the SFU renews the token of everyone it
//! accepts, so a device that lost its network rejoins on its own. What a join may do to the
//! member's other calls is decided by this, never by which connection is the newest.
//! It also remembers when each token was minted and what it let them publish, so a join with no
//! recent mint is known to be a renewed token and a permission change knows what the SFU holds.
//! In memory like its siblings, so a restart forgets it and a join then ends nothing.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;

/// How long a mint is remembered, far past any call that still needs its grants compared.
const FORGET_AFTER: Duration = Duration::from_secs(24 * 3600);

/// What a participant may publish at the SFU: audio from Speak, data from Use Canvas.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Grants {
    pub publish: bool,
    pub publish_data: bool,
}

impl Grants {
    pub fn from_permissions(permissions: Permissions) -> Self {
        Self {
            publish: permissions.contains(Permissions::SPEAK),
            publish_data: permissions.contains(Permissions::USE_CANVAS),
        }
    }
}

struct Minted {
    touched: Instant,
    /// When a token was last minted; `None` for an entry only a grants push created.
    token_at: Option<Instant>,
    grants: Grants,
}

#[derive(Default)]
struct Inner {
    last: HashMap<UserId, ChannelId>,
    minted: HashMap<(UserId, ChannelId), Minted>,
}

#[derive(Clone, Default)]
pub struct AskedCalls {
    state: Arc<Mutex<Inner>>,
}

impl AskedCalls {
    /// Records that `user_id` was handed a token for `channel_id` carrying `grants`.
    pub fn note(&self, user_id: UserId, channel_id: ChannelId, grants: Grants) {
        let mut state = self.lock();
        state.last.insert(user_id, channel_id);
        let now = Instant::now();
        state
            .minted
            .retain(|_, minted| now.saturating_duration_since(minted.touched) < FORGET_AFTER);
        state.minted.insert(
            (user_id, channel_id),
            Minted {
                touched: now,
                token_at: Some(now),
                grants,
            },
        );
    }

    /// The channel `user_id` last asked a token for, if any since startup.
    pub fn last(&self, user_id: UserId) -> Option<ChannelId> {
        self.lock().last.get(&user_id).copied()
    }

    /// Whether a token for this call was minted inside one token lifetime, so a join on it is the
    /// join that mint was for rather than a token the SFU renewed.
    pub fn minted_recently(&self, user_id: UserId, channel_id: ChannelId) -> bool {
        let window = Duration::from_secs(super::TOKEN_TTL_SECS);
        self.lock()
            .minted
            .get(&(user_id, channel_id))
            .and_then(|minted| minted.token_at)
            .is_some_and(|at| at.elapsed() < window)
    }

    /// Whether the SFU is known to hold exactly `grants` for this member: false when they differ
    /// and when nothing is on record, so a restart pushes once instead of trusting a guess.
    pub fn grants_match(&self, user_id: UserId, channel_id: ChannelId, grants: Grants) -> bool {
        self.lock()
            .minted
            .get(&(user_id, channel_id))
            .is_some_and(|minted| minted.grants == grants)
    }

    /// Records the grants the SFU now holds for a member, after pushing them.
    pub fn set_grants(&self, user_id: UserId, channel_id: ChannelId, grants: Grants) {
        let mut state = self.lock();
        let touched = Instant::now();
        state
            .minted
            .entry((user_id, channel_id))
            .and_modify(|minted| {
                minted.grants = grants;
                minted.touched = touched;
            })
            .or_insert(Minted {
                touched,
                token_at: None,
                grants,
            });
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}
