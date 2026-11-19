// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which stale heartbeats the sweep evicts. A heartbeat travels the API path, which can break
//! while the member's call is fine, so the SFU is asked before anyone is removed.

use std::collections::{HashMap, HashSet};
use std::time::Instant;

use futures_util::StreamExt;

use super::heartbeat::{STALE_AFTER, STALE_WHILE_ACTIVE_CAP, StaleCall};
use super::{VoiceError, VoiceService};
use crate::ids::{ChannelId, UserId};

/// How many rooms one sweep asks the SFU about at once.
const ROOM_CHECK_CONCURRENCY: usize = 16;

/// Who the SFU reported `ACTIVE`, per room it answered for.
type ActiveMembers = HashMap<ChannelId, HashSet<UserId>>;

impl VoiceService {
    /// Every `(user, channel)` call to evict as of `now`, forgotten here for the caller to remove
    /// at the SFU: a stale heartbeat the SFU does not vouch for, or one past [`STALE_WHILE_ACTIVE_CAP`].
    pub async fn sweep_stale_calls_at(&self, now: Instant) -> Vec<(UserId, ChannelId)> {
        let stale = self.heartbeats.stale_at(STALE_AFTER, now);
        let rooms: HashSet<ChannelId> = stale
            .iter()
            .filter(|call| call.age_at(now) < STALE_WHILE_ACTIVE_CAP)
            .map(|call| call.channel_id)
            .collect();
        let active = self.active_members(rooms).await;
        stale
            .into_iter()
            .filter(|call| !kept_for_active_media(call, &active, now))
            .filter(|call| self.heartbeats.forget_if_unrefreshed(call))
            .map(|call| (call.user_id, call.channel_id))
            .collect()
    }

    /// A room the SFU could not answer for is left out, so its stale calls are evicted as before.
    async fn active_members(&self, rooms: HashSet<ChannelId>) -> ActiveMembers {
        futures_util::stream::iter(rooms)
            .map(|channel_id| async move { (channel_id, self.list_participants(channel_id).await) })
            .buffer_unordered(ROOM_CHECK_CONCURRENCY)
            .filter_map(|(channel_id, listed)| async move {
                match listed {
                    Ok(participants) => Some((
                        channel_id,
                        participants
                            .into_iter()
                            .filter(|p| p.is_active)
                            .map(|p| p.user_id)
                            .collect(),
                    )),
                    Err(VoiceError::Unavailable) => None,
                    Err(VoiceError::Internal(err)) => {
                        tracing::warn!(
                            error = %err,
                            %channel_id,
                            "could not ask the sfu who is active before evicting stale heartbeats"
                        );
                        None
                    }
                }
            })
            .collect()
            .await
    }
}

fn kept_for_active_media(call: &StaleCall, active: &ActiveMembers, now: Instant) -> bool {
    let age = call.age_at(now);
    let kept = age < STALE_WHILE_ACTIVE_CAP
        && active
            .get(&call.channel_id)
            .is_some_and(|users| users.contains(&call.user_id));
    if kept {
        tracing::info!(
            user_id = %call.user_id,
            channel_id = %call.channel_id,
            heartbeat_age_secs = age.as_secs(),
            "kept a call whose heartbeat is stale while the sfu still reports its media active"
        );
    }
    kept
}
