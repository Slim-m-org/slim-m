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
    /// Whether this member is known to be on the call. An entry a track
    /// webhook created before (or after) its join is provisional until then.
    announced: bool,
    /// Whether the SFU's roster put the entry here rather than a join webhook,
    /// so the join webhook for this sid, if it still arrives, is a real join.
    from_roster: bool,
    /// When the SFU says the roster entry joined, in unix milliseconds.
    joined_at_ms: Option<i64>,
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
            from_roster: false,
            joined_at_ms: None,
            screen_share_tracks: HashSet::new(),
        }
    }
}

type Key = (ChannelId, UserId);

#[derive(Default)]
struct Inner {
    participants: HashMap<Key, ParticipantState>,
    /// The sid whose leave was last published per member, so a duplicate
    /// leave is dropped even though the member's entry is already gone.
    ended: HashMap<Key, String>,
    /// Channels whose members were read off the SFU since this process started,
    /// or whose room finished empty, so webhook state can be trusted for them.
    reconciled: HashSet<ChannelId>,
}

/// Tracks who a LiveKit webhook has told us is on a call, and whether they
/// are sharing their screen right now.
#[derive(Clone, Default)]
pub struct RoomLiveState {
    state: Arc<Mutex<Inner>>,
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
        state.ended.remove(&(channel_id, user_id));
        let entry = state
            .participants
            .entry((channel_id, user_id))
            .or_insert_with(|| ParticipantState::new(sid, false));
        if entry.sid != sid {
            *entry = ParticipantState::new(sid, false);
        }
        let real = !entry.announced || entry.from_roster;
        entry.announced = true;
        entry.from_roster = false;
        real
    }

    /// Records who the SFU says is on a call this process did not see them join,
    /// and marks the channel reconciled.
    ///
    /// A webhook's own knowledge wins: someone already tracked, or whose leave
    /// was already published, is left alone, so a roster read that raced a
    /// webhook cannot bring them back.
    pub fn seed(
        &self,
        channel_id: ChannelId,
        roster: impl IntoIterator<Item = (UserId, String, Option<i64>)>,
    ) {
        let mut state = lock(&self.state);
        for (user_id, sid, joined_at_ms) in roster.into_iter().filter(|(_, sid, _)| !sid.is_empty())
        {
            let key = (channel_id, user_id);
            if state.ended.get(&key) == Some(&sid) {
                continue;
            }
            match state.participants.get_mut(&key) {
                Some(entry) if entry.sid == sid && !entry.announced => {
                    entry.announced = true;
                    entry.from_roster = true;
                    entry.joined_at_ms = joined_at_ms;
                }
                Some(_) => {}
                None => {
                    let mut entry = ParticipantState::new(&sid, true);
                    entry.from_roster = true;
                    entry.joined_at_ms = joined_at_ms;
                    state.participants.insert(key, entry);
                }
            }
        }
        state.reconciled.insert(channel_id);
    }

    /// Whether [`Self::seed`] has run for the channel since the room last emptied.
    pub fn is_reconciled(&self, channel_id: ChannelId) -> bool {
        lock(&self.state).reconciled.contains(&channel_id)
    }

    /// Forgets a participant, reporting whether this leave should publish. A
    /// duplicate leave, or a late one from an earlier session after the member
    /// rejoined, must not. A leave from a session this process never saw join
    /// does: the server restarted mid-call, and staying quiet left the member
    /// shown in the call until the next roster poll.
    pub fn mark_left(&self, channel_id: ChannelId, user_id: UserId, sid: &str) -> bool {
        let key = (channel_id, user_id);
        let mut state = lock(&self.state);
        let publish = match state.participants.get(&key) {
            Some(entry) if entry.sid == sid => state.participants.remove(&key).is_some(),
            Some(_) => false,
            None => state.ended.get(&key).is_none_or(|ended| ended != sid),
        };
        if publish {
            state.ended.insert(key, sid.to_owned());
        }
        publish
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
            .participants
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
        let Some(participant) = state.participants.get_mut(&(channel_id, user_id)) else {
            return false;
        };
        if participant.sid != participant_sid {
            return false;
        }
        participant.screen_share_tracks.remove(track_sid)
            && participant.screen_share_tracks.is_empty()
    }

    /// Who a join webhook announced on `channel_id` and no leave has since removed.
    pub fn present(&self, channel_id: ChannelId) -> Vec<UserId> {
        self.present_where(channel_id, |_| true)
    }

    /// Who was on `channel_id` before a session that joined at `joined_at_ms`.
    ///
    /// The first webhook after a restart finds its neighbours already read off the SFU, and one of
    /// them may have joined a moment after it with a webhook still queued. A member the roster put
    /// here whose own join has not arrived counts only if the SFU stamped them earlier; without a
    /// stamp on both sides they count, as someone who was there all along.
    pub fn present_before(&self, channel_id: ChannelId, joined_at_ms: Option<i64>) -> Vec<UserId> {
        self.present_where(channel_id, |entry| {
            let joined_later = matches!(
                (entry.from_roster, entry.joined_at_ms, joined_at_ms),
                (true, Some(theirs), Some(ours)) if theirs >= ours
            );
            !joined_later
        })
    }

    fn present_where(
        &self,
        channel_id: ChannelId,
        counts: impl Fn(&ParticipantState) -> bool,
    ) -> Vec<UserId> {
        let state = lock(&self.state);
        let mut present: Vec<UserId> = state
            .participants
            .iter()
            .filter(|((channel, _), entry)| {
                *channel == channel_id && entry.announced && counts(entry)
            })
            .map(|((_, user), _)| *user)
            .collect();
        present.sort_by_key(ToString::to_string);
        present
    }

    /// Whether a join webhook announced `user_id` on `channel_id`.
    pub fn is_present(&self, channel_id: ChannelId, user_id: UserId) -> bool {
        lock(&self.state)
            .participants
            .get(&(channel_id, user_id))
            .is_some_and(|entry| entry.announced)
    }

    /// Forgets everyone in a room LiveKit reports finished, so no entry
    /// outlives the room it was about.
    pub fn forget_room(&self, channel_id: ChannelId) {
        let mut state = lock(&self.state);
        state
            .participants
            .retain(|(channel, _), _| *channel != channel_id);
        state.ended.retain(|(channel, _), _| *channel != channel_id);
        state.reconciled.remove(&channel_id);
    }
}

fn lock(state: &Mutex<Inner>) -> MutexGuard<'_, Inner> {
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

    /// Reads a channel's members off the SFU into [`RoomLiveState`] the first
    /// time it is asked after a restart.
    ///
    /// LiveKit never repeats `participant_joined` for people already in a room,
    /// so without this a mid-call deploy leaves them uncounted. A failed read
    /// leaves the channel unreconciled and the next webhook tries again.
    pub async fn reconcile_live_state(&self, channel_id: ChannelId) {
        if self.live_state.is_reconciled(channel_id) {
            return;
        }
        match self.list_participants(channel_id).await {
            Ok(listed) => self.live_state.seed(
                channel_id,
                listed
                    .into_iter()
                    .map(|p| (p.user_id, p.sid, p.joined_at_ms)),
            ),
            Err(err) => {
                tracing::warn!(?err, %channel_id, "could not read a call's members from the SFU")
            }
        }
    }
}

#[cfg(test)]
mod tests;
