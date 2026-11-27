// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Presence held by a REST heartbeat instead of a socket, for clients that cannot open one.
//!
//! A live heartbeat counts as one connection of [`DeviceKind::Unknown`] on the user's entry, so
//! every reader and the fan-out treat it exactly like a socket, and a socket and a heartbeat
//! together read as online until both are gone.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use super::{DeviceKind, Entry, PresenceTracker, Visibility, lock};
use crate::ids::UserId;
use crate::presence_activity::Activity;

/// The longest a single heartbeat keeps a user present.
pub const MAX_TTL: Duration = Duration::from_secs(300);
/// What a heartbeat that names no `ttl_seconds` keeps a user present for.
pub const DEFAULT_TTL: Duration = Duration::from_secs(60);

pub(super) struct Beat {
    expires: Instant,
    generation: u64,
    /// A transient status the heartbeat asked for; a durable non-online choice outranks it.
    status: Visibility,
}

/// What recording a heartbeat did.
pub struct BeatRecorded {
    /// Something a viewer can see changed, so it is worth announcing.
    pub changed: bool,
    /// Present when a new expiry timer must run: the beat's generation and expiry.
    pub timer: Option<(u64, Instant)>,
}

/// What an expiry timer woke up to.
pub enum BeatDue {
    /// The beat ended; `changed` says whether a viewer could see it.
    Ended { changed: bool },
    /// The beat was refreshed; sleep until the new expiry.
    Later(Instant),
    /// The beat this timer belonged to is already gone.
    Gone,
}

impl PresenceTracker {
    /// Records a heartbeat for `user_id` lasting `ttl`, applying `activity` when one was sent.
    pub fn beat(
        &self,
        user_id: UserId,
        ttl: Duration,
        status: Visibility,
        activity: Option<Activity>,
        now: Instant,
    ) -> BeatRecorded {
        let mut state = lock(&self.state);
        let expires = now + ttl.min(MAX_TTL);
        let entry = state.entry(user_id).or_insert_with(|| Entry::empty(now));
        let before = entry.seen();
        let mut timer = None;
        match entry.beat.as_mut() {
            Some(beat) => {
                beat.expires = expires;
                beat.status = status;
            }
            None => {
                let generation = NEXT_GENERATION.fetch_add(1, Ordering::Relaxed);
                entry.connections += 1;
                entry.devices.add(DeviceKind::Unknown);
                entry.beat = Some(Beat {
                    expires,
                    generation,
                    status,
                });
                timer = Some((generation, expires));
            }
        }
        entry.last_active = now;
        let mut changed = entry.seen() != before;
        if let Some(activity) = activity
            && !entry.activity.as_ref().is_some_and(Activity::is_steam)
            && entry.activity.as_ref() != Some(&activity)
        {
            entry.activity = Some(activity);
            changed = true;
        }
        BeatRecorded { changed, timer }
    }

    /// Ends `user_id`'s heartbeat at once. Returns whether a viewer could see the change.
    pub fn end_beat(&self, user_id: UserId) -> bool {
        finish_beat(&mut lock(&self.state), user_id)
    }

    /// An expiry timer's check: ends the beat when it is due and still the one `generation` named.
    pub fn beat_due(&self, user_id: UserId, generation: u64, now: Instant) -> BeatDue {
        let mut state = lock(&self.state);
        let Some(beat) = state
            .get(&user_id)
            .and_then(|entry| entry.beat.as_ref())
            .filter(|beat| beat.generation == generation)
        else {
            return BeatDue::Gone;
        };
        if beat.expires > now {
            return BeatDue::Later(beat.expires);
        }
        BeatDue::Ended {
            changed: finish_beat(&mut state, user_id),
        }
    }

    /// The visibility a viewer's status is derived from: a heartbeat's transient away or dnd
    /// stands in for an `Online` choice only.
    pub fn effective_visibility(&self, user_id: UserId, durable: Visibility) -> Visibility {
        if durable != Visibility::Online {
            return durable;
        }
        lock(&self.state)
            .get(&user_id)
            .and_then(Entry::beat_status)
            .unwrap_or(durable)
    }
}

impl Entry {
    pub(super) fn empty(now: Instant) -> Self {
        Entry {
            connections: 0,
            last_active: now,
            visibility: None,
            activity: None,
            devices: Default::default(),
            beat: None,
        }
    }

    fn beat_status(&self) -> Option<Visibility> {
        self.beat.as_ref().map(|beat| beat.status)
    }

    /// What a viewer can tell apart: which kinds are present, and the transient status.
    fn seen(&self) -> (bool, [bool; 4], Option<Visibility>) {
        (
            self.connections > 0,
            self.devices.signature(),
            self.beat_status(),
        )
    }
}

static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

/// Drops `user_id`'s beat, and the whole entry when nothing else holds it open.
fn finish_beat(state: &mut HashMap<UserId, Entry>, user_id: UserId) -> bool {
    let Some(entry) = state.get_mut(&user_id) else {
        return false;
    };
    if entry.beat.is_none() {
        return false;
    }
    let before = entry.seen();
    entry.beat = None;
    entry.connections = entry.connections.saturating_sub(1);
    entry.devices.remove(DeviceKind::Unknown);
    if entry.connections == 0 {
        state.remove(&user_id);
        return true;
    }
    entry.seen() != before
}
