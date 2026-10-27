// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Ephemeral, in-memory presence: who currently has a live WebSocket, and the
//! one pure rule for what status a given viewer may be told about a given
//! user.
//!
//! Presence is derived from live connections, never self-reported, so a
//! client that crashes cannot stay "online" forever: the only way into
//! [`PresenceTracker`] is a connection actually opening, and the only way out
//! is that connection closing, which `http::ws::serve` guarantees runs on
//! every exit path with a drop guard. Nothing here is written to SQLite: a
//! row per heartbeat would be pure write amplification on an embedded
//! database for a value that is stale the instant it is read back after a
//! crash.
//!
//! The one thing that IS a durable user choice is [`Visibility`]: whether to
//! show up as online, away, or dnd, or to appear offline to everyone else
//! (`Hidden`). That preference lives in SQLite (`users.presence_visibility`,
//! migration 0008); [`crate::store::Store::presence_visibility`] reads it.
//!
//! [`status_for`] is the single place that decides what a viewer sees, and it
//! is deliberately the only place: every surface that exposes presence (the
//! REST batch lookup in `http::presence` and the WebSocket broadcast in
//! `http::ws`) calls this same function with the same inputs, so a hidden
//! user's real status has exactly one choke point to leak through rather than
//! one per surface.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::ids::UserId;
use crate::presence_activity::Activity;
use crate::viewing::ViewingTracker;

mod devices;

use devices::DeviceCounts;
pub use devices::DeviceKind;

pub mod presence_activity;
pub mod typing;
pub mod viewing;

/// How long a connected user with no observed activity (an `active` frame, typing refresh, or a ping from a client that sends no `active`) shows as away rather than online.
/// Only affects the `Online` preference; Away, Dnd and Hidden already said what to show.
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(10 * 60);

/// The status a user has durably chosen, independent of whether they are
/// connected right now. Persisted in `users.presence_visibility`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Visibility {
    #[default]
    Online,
    Away,
    Dnd,
    /// Appear offline to everyone else. The owner's decision record calls
    /// this presence's "hide/appear-offline option"; the user's own client
    /// still sees their true connection-derived state (see [`status_for`]).
    Hidden,
}

impl Visibility {
    pub const fn as_str(self) -> &'static str {
        match self {
            Visibility::Online => "online",
            Visibility::Away => "away",
            Visibility::Dnd => "dnd",
            Visibility::Hidden => "hidden",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "online" => Visibility::Online,
            "away" => Visibility::Away,
            "dnd" => Visibility::Dnd,
            "hidden" => Visibility::Hidden,
            _ => return None,
        })
    }
}

/// What a viewer is told a user's status is. Never `Hidden` on the wire: that
/// preference either renders as `Offline` (any other viewer) or resolves to
/// the real connection-derived status (the user viewing themselves); see
/// [`status_for`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Online,
    Away,
    Dnd,
    Offline,
}

impl Status {
    pub const fn as_str(self) -> &'static str {
        match self {
            Status::Online => "online",
            Status::Away => "away",
            Status::Dnd => "dnd",
            Status::Offline => "offline",
        }
    }
}

/// Resolves what `viewer` may be told about `target`'s presence.
///
/// `connected` and `idle` describe `target`'s live sockets, derived from
/// [`PresenceTracker`], never from anything a client asserts about itself.
/// The one asymmetry is deliberate: a target who chose [`Visibility::Hidden`]
/// is always `Offline` to anyone else, but sees their own true state, because
/// appear-offline is a decision to hide from other people, not from your own
/// client.
pub fn status_for(
    viewer: UserId,
    target: UserId,
    visibility: Visibility,
    connected: bool,
    idle: bool,
) -> Status {
    if !connected {
        return Status::Offline;
    }
    match visibility {
        Visibility::Hidden if viewer != target => Status::Offline,
        Visibility::Hidden => Status::Online,
        Visibility::Dnd => Status::Dnd,
        Visibility::Away => Status::Away,
        Visibility::Online if idle => Status::Away,
        Visibility::Online => Status::Online,
    }
}

/// Tracks, per user, how many live WebSocket connections are open and when
/// one last showed activity. Nothing here is itself a status: these are only
/// the connection facts [`status_for`] combines with a [`Visibility`] to
/// answer what a viewer sees.
#[derive(Clone)]
pub struct PresenceTracker {
    state: Arc<Mutex<HashMap<UserId, Entry>>>,
    viewing: ViewingTracker,
}

struct Entry {
    connections: u32,
    last_active: Instant,
    /// The user's durable visibility choice, cached from SQLite for this
    /// connection's lifetime so authorizing a presence change reads it from
    /// memory instead of a per-viewer database round trip. `None` until the
    /// connection loads it; readers fall back to the store in that window.
    visibility: Option<Visibility>,
    /// What the user last said they are doing; dies with the entry.
    activity: Option<Activity>,
    /// Live sockets per kind of client, so a viewer can tell phone from desktop.
    devices: DeviceCounts,
}

impl Default for PresenceTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl PresenceTracker {
    pub fn new() -> Self {
        Self {
            state: Arc::new(Mutex::new(HashMap::new())),
            viewing: ViewingTracker::default(),
        }
    }

    /// The open-channel reports beside the connection counts, shared so the
    /// push path, which already carries a tracker, needs no extra handle.
    pub fn viewing(&self) -> ViewingTracker {
        self.viewing.clone()
    }

    /// Records a new live connection. Returns `true` if this is the user's
    /// first (a transition worth publishing); a second device connecting
    /// while the first is still live is not a change anyone needs telling
    /// about.
    pub fn connect(&self, user_id: UserId) -> bool {
        self.connect_at(user_id, Instant::now())
    }

    /// [`Self::connect`] with an explicit clock, so a test can drive idle
    /// timing deterministically instead of sleeping.
    pub fn connect_at(&self, user_id: UserId, now: Instant) -> bool {
        self.connect_kind_at(user_id, DeviceKind::Unknown, true, now)
    }

    /// [`Self::connect`] naming the client's kind; true when presence visibly changed (first socket, or a kind not yet connected).
    /// `active` is false only for a client that reports activity itself and says nobody is at the device, so a reconnect after sleep is not use.
    pub fn connect_as(&self, user_id: UserId, kind: DeviceKind, active: bool) -> bool {
        self.connect_kind_at(user_id, kind, active, Instant::now())
    }

    fn connect_kind_at(
        &self,
        user_id: UserId,
        kind: DeviceKind,
        active: bool,
        now: Instant,
    ) -> bool {
        let mut state = lock(&self.state);
        let arrived_idle = now.checked_sub(IDLE_TIMEOUT).unwrap_or(now);
        let entry = state.entry(user_id).or_insert(Entry {
            connections: 0,
            last_active: if active { now } else { arrived_idle },
            visibility: None,
            activity: None,
            devices: DeviceCounts::default(),
        });
        let before = entry.devices.signature();
        entry.connections += 1;
        entry.devices.add(kind);
        if active {
            entry.last_active = now;
        }
        entry.connections == 1 || before != entry.devices.signature()
    }

    /// Records a connection closing. Returns `true` if that was the user's
    /// last live connection.
    pub fn disconnect(&self, user_id: UserId) -> bool {
        self.disconnect_as(user_id, DeviceKind::Unknown)
    }

    /// [`Self::disconnect`] naming the closing client's kind. Returns `true`
    /// when presence visibly changed: the last socket, or the last of a kind.
    pub fn disconnect_as(&self, user_id: UserId, kind: DeviceKind) -> bool {
        let mut state = lock(&self.state);
        let Some(entry) = state.get_mut(&user_id) else {
            return false;
        };
        let before = entry.devices.signature();
        entry.connections = entry.connections.saturating_sub(1);
        entry.devices.remove(kind);
        if entry.connections == 0 {
            state.remove(&user_id);
            true
        } else {
            before != entry.devices.signature()
        }
    }

    /// Marks a connected user as recently active, resetting the idle clock.
    pub fn touch(&self, user_id: UserId) {
        self.touch_at(user_id, Instant::now());
    }

    /// [`Self::touch`] with an explicit clock.
    pub fn touch_at(&self, user_id: UserId, now: Instant) {
        if let Some(entry) = lock(&self.state).get_mut(&user_id) {
            entry.last_active = now;
        }
    }

    /// Authoritatively caches [user_id]'s visibility choice, if connected. The
    /// visibility endpoint calls this the instant a user changes their choice,
    /// so it always overwrites. A no-op when not connected: nothing off a live
    /// connection needs it, and the entry is created and removed with the
    /// connection.
    pub fn set_visibility(&self, user_id: UserId, visibility: Visibility) {
        if let Some(entry) = lock(&self.state).get_mut(&user_id) {
            entry.visibility = Some(visibility);
        }
    }

    /// Fills in [user_id]'s cached visibility on connect, but only if nothing
    /// is cached yet. A concurrent [`Self::set_visibility`] from the endpoint
    /// is the authoritative choice; a connect whose store read raced ahead of
    /// that write must never clobber it back to the stale value.
    pub fn load_visibility(&self, user_id: UserId, visibility: Visibility) {
        if let Some(entry) = lock(&self.state).get_mut(&user_id) {
            entry.visibility.get_or_insert(visibility);
        }
    }

    /// [user_id]'s cached visibility, or `None` when it is not connected or
    /// has not loaded yet - the caller then reads the durable value from the
    /// store, so a miss is exactly the old behaviour, never a wrong answer.
    pub fn visibility(&self, user_id: UserId) -> Option<Visibility> {
        lock(&self.state).get(&user_id).and_then(|e| e.visibility)
    }

    /// Replaces [user_id]'s activity. Returns whether anything changed, so an
    /// unchanged repeat is not re-announced; a user with no live socket has
    /// nowhere to hold it and reads as unchanged.
    pub fn set_activity(&self, user_id: UserId, activity: Option<Activity>) -> bool {
        let mut state = lock(&self.state);
        let Some(entry) = state.get_mut(&user_id) else {
            return false;
        };
        let changed = entry.activity != activity;
        entry.activity = activity;
        changed
    }

    /// What a viewer may be told [target] is doing: nothing whenever `status`
    /// (already resolved by [`status_for`]) reads offline, which is how a
    /// hidden user's activity stays hidden through the same choke point.
    pub fn activity_visible_at(&self, target: UserId, status: Status) -> Option<Activity> {
        if status == Status::Offline {
            return None;
        }
        lock(&self.state)
            .get(&target)
            .and_then(|e| e.activity.clone())
    }

    pub fn is_connected(&self, user_id: UserId) -> bool {
        lock(&self.state).contains_key(&user_id)
    }

    pub fn is_idle(&self, user_id: UserId) -> bool {
        self.is_idle_at(user_id, Instant::now())
    }

    /// [`Self::is_idle`] with an explicit clock.
    pub fn is_idle_at(&self, user_id: UserId, now: Instant) -> bool {
        lock(&self.state)
            .get(&user_id)
            .map(|entry| now.duration_since(entry.last_active) >= IDLE_TIMEOUT)
            .unwrap_or(false)
    }
}

/// A poisoned lock means another thread panicked mid-update; recover rather
/// than wedging every presence read behind a dead tracker, the same choice
/// [`crate::ratelimit::RateLimiter`] makes.
fn lock(state: &Mutex<HashMap<UserId, Entry>>) -> MutexGuard<'_, HashMap<UserId, Entry>> {
    match state.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

#[cfg(test)]
mod tests;
