// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who is on a channel's call: LiveKit's webhook roster when it can be trusted, the SFU otherwise.

use crate::ids::{ChannelId, UserId};

use super::VoiceService;

/// How a caller that has to ask the SFU wants it asked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Listing {
    /// A fresh round trip, for callers that act on who is present.
    Fresh,
    /// [`VoiceService::list_participants_shared`], for callers that only address who is present.
    Shared,
}

impl VoiceService {
    /// The webhook roster when it can be trusted: someone is known and the channel was read off
    /// the SFU since a restart. `None` means only the SFU can say.
    pub fn trusted_roster(&self, channel_id: ChannelId) -> Option<Vec<UserId>> {
        let live = self.live_state();
        let present = live.present(channel_id);
        (!present.is_empty() && live.is_reconciled(channel_id)).then_some(present)
    }

    /// [`Self::trusted_roster`], else the SFU's own list, else the untrusted roster when the SFU
    /// cannot be reached.
    pub async fn in_call(&self, channel_id: ChannelId, listing: Listing) -> Vec<UserId> {
        if let Some(present) = self.trusted_roster(channel_id) {
            return present;
        }
        let listed = match listing {
            Listing::Fresh => self.list_participants(channel_id).await,
            Listing::Shared => self.list_participants_shared(channel_id).await,
        };
        match listed {
            Ok(listed) => listed.into_iter().map(|p| p.user_id).collect(),
            Err(_) => self.live_state().present(channel_id),
        }
    }
}
