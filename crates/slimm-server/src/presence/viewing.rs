// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which channels a user's live connections report as open and in front of
//! them right now, so push can skip a message somebody is already reading.
//!
//! In-memory and per connection, like [`crate::presence::PresenceTracker`]:
//! a report lapses on its own after [`VIEWING_TTL`], so a client that is
//! suspended without closing its socket cannot silence push forever. It is
//! only ever read by the push path for the reporting user's own account and
//! is never broadcast, so a hidden presence stays hidden.
//!
//! Reports are keyed by user, then connection, so a frame or a push check
//! touches only that user's own few connections rather than every report on
//! the deployment. Lapsed reports are pruned per user on that user's next
//! frame, and a connection's own exit removes its entry.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::ids::{ChannelId, DeviceId, UserId};

/// How long any foreground signal counts, the websocket viewing report and a
/// device's push lifecycle report alike, so neither can outlive the other.
/// Clients refresh both well inside this.
pub const FOREGROUND_FRESHNESS: Duration = Duration::from_secs(60);

/// How long one viewing report counts.
pub const VIEWING_TTL: Duration = FOREGROUND_FRESHNESS;

/// The one place that decides what a lifecycle label means: only "foreground"
/// is foreground, and anything else is a device that has stepped back.
pub fn is_foreground_label(state: &str) -> bool {
    state == "foreground"
}

/// How long after a connection last reported its user active that the account
/// counts as in front of a device, so a phone push for a message would only
/// duplicate what that device already shows. Two minutes: long enough to cover
/// reading without typing, short enough that walking away soon restores push.
pub const ACTIVE_WINDOW: Duration = Duration::from_secs(120);

/// The most channels one connection may report at once; a thread and its
/// parent are the realistic ceiling, the rest is abuse.
pub const MAX_VIEWED_CHANNELS: usize = 8;

struct Report {
    device: DeviceId,
    channels: HashSet<ChannelId>,
    at: Instant,
}

#[derive(Clone, Default)]
pub struct ViewingTracker {
    reports: Arc<Mutex<HashMap<UserId, HashMap<u64, Report>>>>,
    active: Arc<Mutex<HashMap<UserId, HashMap<u64, Instant>>>>,
    next_connection: Arc<AtomicU64>,
}

impl ViewingTracker {
    /// A fresh id for one live connection, to key its reports by.
    pub fn new_connection(&self) -> u64 {
        self.next_connection.fetch_add(1, Ordering::Relaxed)
    }

    /// Replaces what `connection` reports as open; an empty set clears it.
    pub fn set(
        &self,
        user_id: UserId,
        device: DeviceId,
        connection: u64,
        channels: HashSet<ChannelId>,
    ) {
        self.set_at(user_id, device, connection, channels, Instant::now());
    }

    pub fn set_at(
        &self,
        user_id: UserId,
        device: DeviceId,
        connection: u64,
        channels: HashSet<ChannelId>,
        now: Instant,
    ) {
        if channels.is_empty() {
            self.clear(user_id, connection);
            return;
        }
        let mut reports = lock(&self.reports);
        let own = reports.entry(user_id).or_default();
        own.retain(|_, report| now.duration_since(report.at) < VIEWING_TTL);
        own.insert(
            connection,
            Report {
                device,
                channels,
                at: now,
            },
        );
    }

    /// Forgets a connection's channel report.
    pub fn clear(&self, user_id: UserId, connection: u64) {
        let mut reports = lock(&self.reports);
        if let Some(own) = reports.get_mut(&user_id) {
            own.remove(&connection);
            if own.is_empty() {
                reports.remove(&user_id);
            }
        }
    }

    /// Forgets everything a connection reported, on every exit path of its socket.
    pub fn forget_connection(&self, user_id: UserId, connection: u64) {
        self.clear(user_id, connection);
        let mut active = lock(&self.active);
        if let Some(own) = active.get_mut(&user_id) {
            own.remove(&connection);
            if own.is_empty() {
                active.remove(&user_id);
            }
        }
    }

    /// Records that `connection`'s user was just using that device.
    pub fn mark_active(&self, user_id: UserId, connection: u64) {
        self.mark_active_at(user_id, connection, Instant::now());
    }

    pub fn mark_active_at(&self, user_id: UserId, connection: u64, now: Instant) {
        let mut active = lock(&self.active);
        let own = active.entry(user_id).or_default();
        own.retain(|_, at| now.duration_since(*at) < ACTIVE_WINDOW);
        own.insert(connection, now);
    }

    /// Whether any live connection of `user_id` reported its user active
    /// within [`ACTIVE_WINDOW`].
    pub fn is_recently_active(&self, user_id: UserId) -> bool {
        self.is_recently_active_at(user_id, Instant::now())
    }

    pub fn is_recently_active_at(&self, user_id: UserId, now: Instant) -> bool {
        lock(&self.active).get(&user_id).is_some_and(|own| {
            own.values()
                .any(|at| now.duration_since(*at) < ACTIVE_WINDOW)
        })
    }

    /// Drops every report from one device, for when its lifecycle report says
    /// it is no longer in front of the user.
    pub fn clear_device(&self, user_id: UserId, device: DeviceId) {
        let mut reports = lock(&self.reports);
        if let Some(own) = reports.get_mut(&user_id) {
            own.retain(|_, report| report.device != device);
            if own.is_empty() {
                reports.remove(&user_id);
            }
        }
    }

    /// Whether any live connection of `user_id` reported `channel_id` open
    /// within [`VIEWING_TTL`].
    pub fn is_viewing(&self, user_id: UserId, channel_id: ChannelId) -> bool {
        self.is_viewing_at(user_id, channel_id, Instant::now())
    }

    pub fn is_viewing_at(&self, user_id: UserId, channel_id: ChannelId, now: Instant) -> bool {
        lock(&self.reports).get(&user_id).is_some_and(|own| {
            own.values().any(|report| {
                report.channels.contains(&channel_id) && now.duration_since(report.at) < VIEWING_TTL
            })
        })
    }
}

/// A poisoned lock means another thread panicked mid-update; recover rather
/// than wedge the push path, the choice `presence` makes too.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn one(channel: ChannelId) -> HashSet<ChannelId> {
        HashSet::from([channel])
    }

    #[test]
    fn clearing_a_device_drops_only_its_reports() {
        let tracker = ViewingTracker::default();
        let (user, channel) = (UserId::generate(), ChannelId::generate());
        let (phone, laptop) = (DeviceId::generate(), DeviceId::generate());
        tracker.set(user, phone, 1, one(channel));
        tracker.clear_device(user, laptop);
        assert!(tracker.is_viewing(user, channel));
        tracker.set(user, laptop, 2, one(channel));
        tracker.clear_device(user, phone);
        assert!(
            tracker.is_viewing(user, channel),
            "the laptop still reports it"
        );
        tracker.clear_device(user, laptop);
        assert!(!tracker.is_viewing(user, channel));
        assert!(lock(&tracker.reports).is_empty());
    }

    #[test]
    fn only_the_foreground_label_counts() {
        assert!(is_foreground_label("foreground"));
        assert!(!is_foreground_label("background"));
        assert!(!is_foreground_label(""));
    }

    #[test]
    fn a_report_lapses_after_the_ttl() {
        let tracker = ViewingTracker::default();
        let (user, channel) = (UserId::generate(), ChannelId::generate());
        let start = Instant::now();
        tracker.set_at(user, DeviceId(uuid::Uuid::nil()), 1, one(channel), start);
        assert!(tracker.is_viewing_at(user, channel, start + VIEWING_TTL - Duration::from_secs(1)));
        assert!(!tracker.is_viewing_at(user, channel, start + VIEWING_TTL));
    }

    #[test]
    fn clearing_one_connection_keeps_another() {
        let tracker = ViewingTracker::default();
        let (user, channel) = (UserId::generate(), ChannelId::generate());
        tracker.set(user, DeviceId(uuid::Uuid::nil()), 1, one(channel));
        tracker.set(user, DeviceId(uuid::Uuid::nil()), 2, one(channel));
        tracker.clear(user, 1);
        assert!(tracker.is_viewing(user, channel));
        tracker.set(user, DeviceId(uuid::Uuid::nil()), 2, HashSet::new());
        assert!(!tracker.is_viewing(user, channel));
    }

    #[test]
    fn a_frame_touches_only_its_own_users_reports() {
        let tracker = ViewingTracker::default();
        let (idle, busy, channel) = (
            UserId::generate(),
            UserId::generate(),
            ChannelId::generate(),
        );
        let start = Instant::now();
        tracker.set_at(idle, DeviceId(uuid::Uuid::nil()), 1, one(channel), start);
        let later = start + VIEWING_TTL + Duration::from_secs(1);
        tracker.set_at(busy, DeviceId(uuid::Uuid::nil()), 1, one(channel), later);
        // A whole-map sweep would have dropped the lapsed report of `idle`.
        assert!(lock(&tracker.reports).contains_key(&idle));
        tracker.set_at(idle, DeviceId(uuid::Uuid::nil()), 1, one(channel), later);
        tracker.set_at(idle, DeviceId(uuid::Uuid::nil()), 2, one(channel), later);
        assert_eq!(lock(&tracker.reports)[&idle].len(), 2);
    }

    #[test]
    fn a_users_lapsed_connection_is_pruned_on_their_next_frame() {
        let tracker = ViewingTracker::default();
        let (user, channel) = (UserId::generate(), ChannelId::generate());
        let start = Instant::now();
        tracker.set_at(user, DeviceId(uuid::Uuid::nil()), 1, one(channel), start);
        tracker.set_at(
            user,
            DeviceId(uuid::Uuid::nil()),
            2,
            one(channel),
            start + VIEWING_TTL,
        );
        assert_eq!(lock(&tracker.reports)[&user].len(), 1);
    }

    #[test]
    fn clearing_the_last_connection_forgets_the_user() {
        let tracker = ViewingTracker::default();
        let (user, channel) = (UserId::generate(), ChannelId::generate());
        tracker.set(user, DeviceId(uuid::Uuid::nil()), 1, one(channel));
        tracker.clear(user, 1);
        assert!(lock(&tracker.reports).is_empty());
    }

    #[test]
    fn another_user_is_never_reported_as_viewing() {
        let tracker = ViewingTracker::default();
        let channel = ChannelId::generate();
        tracker.set(
            UserId::generate(),
            DeviceId(uuid::Uuid::nil()),
            1,
            one(channel),
        );
        assert!(!tracker.is_viewing(UserId::generate(), channel));
    }

    #[test]
    fn activity_counts_for_a_half_open_window() {
        let tracker = ViewingTracker::default();
        let user = UserId::generate();
        let start = Instant::now();
        tracker.mark_active_at(user, 1, start);
        assert!(tracker.is_recently_active_at(user, start));
        assert!(
            tracker.is_recently_active_at(user, start + ACTIVE_WINDOW - Duration::from_millis(1))
        );
        assert!(!tracker.is_recently_active_at(user, start + ACTIVE_WINDOW));
    }

    #[test]
    fn a_closed_connection_stops_counting_as_active() {
        let tracker = ViewingTracker::default();
        let user = UserId::generate();
        tracker.mark_active(user, 1);
        tracker.mark_active(user, 2);
        tracker.forget_connection(user, 1);
        assert!(tracker.is_recently_active(user));
        tracker.forget_connection(user, 2);
        assert!(!tracker.is_recently_active(user));
    }
}
