// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Ending a channel's voice room outright, rather than one participant at a
//! time.
//!
//! [`super::VoiceService::remove_participant`] answers "this person may no
//! longer be here"; this answers "this room may no longer exist". The two are
//! not interchangeable, and reaching for the wrong one is how a deleted
//! channel kept hosting a live call: evicting every participant leaves the
//! room itself alive, so anybody still holding an unexpired token can rejoin
//! a channel that is gone. `DeleteRoom` disconnects everyone *and* removes
//! the room, which is the only shape that closes both halves at once.

use crate::ids::ChannelId;

use super::{VoiceError, VoiceService, room_for_channel};

impl VoiceService {
    /// Ends a channel's voice room, disconnecting everyone still in it.
    ///
    /// Deliberately not gated on the channel's `kind`. A room nobody ever
    /// created answers the same as one that emptied out, so calling this for
    /// a text channel costs one request and changes nothing - whereas a
    /// `kind == "voice"` filter is exactly the shape this project has already
    /// had to fix twice, once when DM calls arrived and once when threads
    /// did, each time because a routine was written against the channel kinds
    /// that happened to exist that week.
    ///
    /// Best-effort by design, like its sibling: it is called after the
    /// deletion it accompanies has already committed, so there is nothing
    /// useful a caller could do with a failure that retrying the whole
    /// request would not do better.
    pub async fn delete_room(&self, channel_id: ChannelId) -> Result<(), VoiceError> {
        let Some(enabled) = self.inner.as_ref() else {
            return Err(VoiceError::Unavailable);
        };
        let room = room_for_channel(channel_id);
        // A room that never existed is already in the state this asks for.
        self.room_service_call(
            enabled,
            "DeleteRoom",
            &room,
            serde_json::json!({ "room": room }),
        )
        .await?;
        Ok(())
    }
}
