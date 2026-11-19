// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The call each member last asked a join token for, which is the call their person chose last.
//!
//! A connection can walk back into a room without asking: the SFU renews the token of everyone it
//! accepts, so a device that lost its network rejoins on its own. What a join may do to the
//! member's other calls is decided by this, never by which connection is the newest.
//! In memory like its siblings, so a restart forgets it and a join then ends nothing.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::ids::{ChannelId, UserId};

#[derive(Clone, Default)]
pub struct AskedCalls {
    last: Arc<Mutex<HashMap<UserId, ChannelId>>>,
}

impl AskedCalls {
    /// Records that `user_id` was handed a token for `channel_id`.
    pub fn note(&self, user_id: UserId, channel_id: ChannelId) {
        self.lock().insert(user_id, channel_id);
    }

    /// The channel `user_id` last asked a token for, if any since startup.
    pub fn last(&self, user_id: UserId) -> Option<ChannelId> {
        self.lock().get(&user_id).copied()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<UserId, ChannelId>> {
        self.last
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}
