// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Idempotent state derived from LiveKit webhooks, so a retried or duplicate
//! delivery cannot double-publish a join, leave or screen-share change.
//!
//! Mirrors `voice::heartbeat`'s `CallHeartbeats`: a lock-held check-and-write
//! per transition rather than a separate read then write, for the same
//! reason - two webhooks for the same transition racing each other must
//! still agree on exactly one of them being the one that publishes. See
//! `docs/decisions/0032-voice-participant-webhooks.md`.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};

use crate::ids::{ChannelId, UserId};

use super::VoiceService;

struct ParticipantState {
    /// The LiveKit participant sid this entry belongs to. A webhook from an
    /// earlier session of the same member arrives with a different sid and
    /// must not act on the current one.
    sid: String,
    /// Whether a join was published for this sid. An entry a track webhook
    /// created before (or after) its join is provisional until then.
    announced: bool,
    /// Sids of currently-published screen-share-sourced tracks. A screen
    /// share with audio publishes two tracks, so "is sharing" is "this set
    /// is non-empty", not "a track was published".
    screen_share_tracks: HashSet<String>,
}

impl ParticipantState {
    fn new(sid: &str, announced: bool) -> Self {
        Self {
            sid: sid.to_owned(),
            announced,
            screen_share_tracks: HashSet::new(),
        }
    }
}

type Key = (ChannelId, UserId);

/// Tracks who a LiveKit webhook has told us is on a call, and whether they
/// are sharing their screen right now.
#[derive(Clone, Default)]
pub struct RoomLiveState {
    state: Arc<Mutex<HashMap<Key, ParticipantState>>>,
}

impl RoomLiveState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Records a join, reporting whether this is a real transition - a
    /// duplicate `participant_joined` webhook for the same session must not
    /// republish, while a provisional entry or an earlier session's leftover
    /// must not swallow it either.
    pub fn mark_joined(&self, channel_id: ChannelId, user_id: UserId, sid: &str) -> bool {
        let mut state = lock(&self.state);
        let entry = state
            .entry((channel_id, user_id))
            .or_insert_with(|| ParticipantState::new(sid, false));
        if entry.sid != sid {
            *entry = ParticipantState::new(sid, false);
        }
        !std::mem::replace(&mut entry.announced, true)
    }

    /// Forgets a participant, reporting whether this leave ended the session
    /// we know about - a duplicate leave, or a late one from an earlier
    /// session after the member rejoined, must not republish.
    pub fn mark_left(&self, channel_id: ChannelId, user_id: UserId, sid: &str) -> bool {
        let mut state = lock(&self.state);
        match state.get(&(channel_id, user_id)) {
            Some(entry) if entry.sid == sid => state.remove(&(channel_id, user_id)).is_some(),
            _ => false,
        }
    }

    /// Records a screen-share track publish, reporting `true` only when this
    /// is the track that made the participant start sharing - a second
    /// screen-share track (video's own audio) publishing while the first is
    /// still up is not a fresh "started sharing".
    ///
    /// A track from an unknown participant creates a provisional entry: LiveKit
    /// does not order `track_published` against `participant_joined`, and
    /// dropping it would mean never learning they are sharing. The entry stays
    /// unannounced, so the join that follows still publishes.
    pub fn track_published(
        &self,
        channel_id: ChannelId,
        (user_id, participant_sid): (UserId, &str),
        track_sid: &str,
    ) -> bool {
        let mut state = lock(&self.state);
        let participant = state
            .entry((channel_id, user_id))
            .or_insert_with(|| ParticipantState::new(participant_sid, false));
        if participant.sid != participant_sid {
            return false;
        }
        let was_sharing = !participant.screen_share_tracks.is_empty();
        participant.screen_share_tracks.insert(track_sid.to_owned());
        !was_sharing
    }

    /// Records a screen-share track unpublish, reporting `true` only when
    /// this call removed the participant's last screen-share track - a
    /// duplicate webhook for a track already gone is not a second stop.
    pub fn track_unpublished(
        &self,
        channel_id: ChannelId,
        (user_id, participant_sid): (UserId, &str),
        track_sid: &str,
    ) -> bool {
        let mut state = lock(&self.state);
        let Some(participant) = state.get_mut(&(channel_id, user_id)) else {
            return false;
        };
        if participant.sid != participant_sid {
            return false;
        }
        participant.screen_share_tracks.remove(track_sid)
            && participant.screen_share_tracks.is_empty()
    }

    /// Forgets everyone in a room LiveKit reports finished, so no entry
    /// outlives the room it was about.
    pub fn forget_room(&self, channel_id: ChannelId) {
        lock(&self.state).retain(|(channel, _), _| *channel != channel_id);
    }
}

fn lock(
    state: &Mutex<HashMap<Key, ParticipantState>>,
) -> MutexGuard<'_, HashMap<Key, ParticipantState>> {
    match state.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

impl VoiceService {
    /// The shared, cloneable live-state tracker; see this module's own doc.
    pub fn live_state(&self) -> RoomLiveState {
        self.live_state.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uid() -> UserId {
        UserId::generate()
    }

    fn cid() -> ChannelId {
        ChannelId::generate()
    }

    #[test]
    fn a_first_join_is_a_real_transition() {
        let state = RoomLiveState::new();
        assert!(state.mark_joined(cid(), uid(), "PA"));
    }

    #[test]
    fn a_duplicate_join_webhook_does_not_republish() {
        let state = RoomLiveState::new();
        let (channel, user) = (cid(), uid());
        assert!(state.mark_joined(channel, user, "PA"));
        assert!(!state.mark_joined(channel, user, "PA"));
    }

    #[test]
    fn leaving_someone_unknown_reports_no_transition() {
        let state = RoomLiveState::new();
        assert!(!state.mark_left(cid(), uid(), "PA"));
    }

    #[test]
    fn a_duplicate_leave_webhook_does_not_republish() {
        let state = RoomLiveState::new();
        let (channel, user) = (cid(), uid());
        state.mark_joined(channel, user, "PA");
        assert!(state.mark_left(channel, user, "PA"));
        assert!(!state.mark_left(channel, user, "PA"));
    }

    #[test]
    fn the_first_screen_share_track_starts_sharing() {
        let state = RoomLiveState::new();
        let (channel, user) = (cid(), uid());
        state.mark_joined(channel, user, "PA");
        assert!(state.track_published(channel, (user, "PA"), "track-video"));
    }

    #[test]
    fn a_second_screen_share_track_is_not_a_fresh_start() {
        let state = RoomLiveState::new();
        let (channel, user) = (cid(), uid());
        state.mark_joined(channel, user, "PA");
        assert!(state.track_published(channel, (user, "PA"), "track-video"));
        assert!(!state.track_published(channel, (user, "PA"), "track-audio"));
    }

    #[test]
    fn sharing_stops_only_once_every_screen_share_track_is_gone() {
        let state = RoomLiveState::new();
        let (channel, user) = (cid(), uid());
        state.mark_joined(channel, user, "PA");
        state.track_published(channel, (user, "PA"), "track-video");
        state.track_published(channel, (user, "PA"), "track-audio");

        assert!(
            !state.track_unpublished(channel, (user, "PA"), "track-video"),
            "the audio track is still up"
        );
        assert!(
            state.track_unpublished(channel, (user, "PA"), "track-audio"),
            "that was the last screen-share track"
        );
    }

    #[test]
    fn unpublishing_a_track_for_someone_unknown_reports_no_transition() {
        let state = RoomLiveState::new();
        assert!(!state.track_unpublished(cid(), (uid(), "PA"), "track-video"));
    }

    #[test]
    fn a_track_published_before_any_join_webhook_still_counts() {
        let state = RoomLiveState::new();
        let (channel, user) = (cid(), uid());
        assert!(state.track_published(channel, (user, "PA"), "track-video"));
    }

    #[test]
    fn a_duplicate_unpublish_is_not_a_second_stop() {
        let state = RoomLiveState::new();
        let (channel, user) = (cid(), uid());
        state.mark_joined(channel, user, "PA");
        state.track_published(channel, (user, "PA"), "track-video");
        assert!(state.track_unpublished(channel, (user, "PA"), "track-video"));
        assert!(!state.track_unpublished(channel, (user, "PA"), "track-video"));
    }

    #[test]
    fn a_join_after_an_early_track_still_publishes() {
        let state = RoomLiveState::new();
        let (channel, user) = (cid(), uid());
        assert!(state.track_published(channel, (user, "PA"), "track-video"));
        assert!(state.mark_joined(channel, user, "PA"));
        assert!(!state.mark_joined(channel, user, "PA"));
    }

    #[test]
    fn a_late_track_after_leaving_does_not_swallow_the_next_join() {
        let state = RoomLiveState::new();
        let (channel, user) = (cid(), uid());
        state.mark_joined(channel, user, "PA");
        assert!(state.mark_left(channel, user, "PA"));
        state.track_published(channel, (user, "PA"), "track-video");
        assert!(
            state.mark_joined(channel, user, "PB"),
            "the rejoin was swallowed"
        );
    }

    #[test]
    fn a_late_leave_from_an_earlier_session_is_ignored() {
        let state = RoomLiveState::new();
        let (channel, user) = (cid(), uid());
        state.mark_joined(channel, user, "PA");
        assert!(state.mark_joined(channel, user, "PB"));
        assert!(!state.mark_left(channel, user, "PA"));
        assert!(state.mark_left(channel, user, "PB"));
    }

    #[test]
    fn a_finished_room_forgets_its_participants() {
        let state = RoomLiveState::new();
        let (channel, user) = (cid(), uid());
        state.mark_joined(channel, user, "PA");
        state.forget_room(channel);
        assert!(state.mark_joined(channel, user, "PA"));
    }
}
