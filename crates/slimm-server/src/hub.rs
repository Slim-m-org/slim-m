// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The in-process fan-out hub.
//!
//! Durable writes happen over REST; this hub carries the resulting events to
//! every connected WebSocket. It is two broadcast channels, one per event
//! class rather than one per scope: publishers (the REST handlers, and a few
//! WebSocket-originated signals) send an [`Event`], [`Hub::publish`] routes it
//! to the durable or the ephemeral channel by [`is_ephemeral`], and each
//! connection subscribes to both and filters events down to what its user is
//! allowed to see. Two class-based channels is ample for the small
//! self-hosted deployments this targets, and a per-scope router can replace
//! either half later without changing the publish side.
//!
//! Delivery order across concurrent writers is best-effort: two racing sends to
//! the same channel may fan out in either order, and the two channels carry no
//! ordering relative to each other at all. Clients apply durable events
//! strictly by their per-scope `seq`, so a brief out-of-order arrival is
//! reconciled on the client and never surfaces as reordering; ephemeral events
//! carry no `seq` and no ordering guarantee to begin with.
//!
//! A durable subscriber that falls too far behind is dropped by its channel (a
//! `Lagged` receive); the connection treats that as backpressure and closes,
//! and the client resyncs over REST. An ephemeral subscriber that falls behind
//! is *not* treated as backpressure: the connection skips forward and keeps
//! running, because losing a stale cursor position or stroke preview is
//! strictly better than forcing a full resync over it. Nothing here blocks a
//! publisher on either channel.
//!
//! The hub also hands out connection slots, capping how many WebSockets can be
//! open at once so a connection flood cannot exhaust the process, and gates
//! the same admission on memory headroom; see the `memory_guard` submodule's
//! own doc comment.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::{OwnedSemaphorePermit, Semaphore, broadcast};

use crate::ephemeral::EphemeralBudget;
use crate::presence::PresenceTracker;
use crate::typing::TypingTracker;

mod created_lookups;
mod event;
mod event_class;
mod event_util;
mod handshake;
mod memory_guard;
mod moderation_seq;
mod screen_annotation;
mod screen_consent;
pub use created_lookups::{CreatedFacts, CreatedLookups};
pub use event::{
    CanvasEvent, Event, MessageEvent, PresenceChange, RoleChange, RoleLook, VoiceRemovalReason,
};
use event_class::is_ephemeral;
pub(crate) use event_class::moves_permissions;
pub use event_util::ReactionMoved;
pub use handshake::PendingGuard;
use memory_guard::MemoryGuard;
pub use memory_guard::{MemoryAdmissionSnapshot, MemoryReading, RESERVE_BYTES, memory_limit_bytes};
use moderation_seq::{ModerationClock, is_moderation};
pub use screen_annotation::{ScreenAnnotationEvent, ScreenAnnotationKind, Stamp, StampContent};
pub use screen_consent::ScreenConsent;

/// How many events the durable channel buffers per subscriber before the
/// slowest one starts losing the oldest and receives a `Lagged` error.
/// Referenced from [`Event`]'s own doc comments, in `hub/event.rs`, as the
/// bound a canvas frame is sized against.
pub(crate) const CHANNEL_CAPACITY: usize = 1024;

/// How many events the ephemeral channel buffers before the slowest
/// subscriber starts losing the oldest.
///
/// Sized against the busiest classes it carries, all rate-limited (see
/// `crate::ratelimit::Class`): per drawer a cursor sustains 15/sec, an object
/// preview 15/sec, and a stroke preview is byte-metered but flushed about 20
/// times a second, so one drawer is up to roughly 50 events/sec. Four drawers
/// seen by a backgrounded phone is 200/sec; 4096 gives that about 20 seconds
/// before the oldest frame is dropped, and a stale cursor costs nothing.
///
/// A tokio broadcast channel keeps one shared ring of slots, not one per
/// subscriber, so memory is this many `Event`-sized slots in total, and the
/// point lists inside are `Arc`-shared.
pub(crate) const EPHEMERAL_CHANNEL_CAPACITY: usize = 4096;

/// Ceiling on simultaneously open WebSocket connections.
pub const MAX_CONNECTIONS: usize = 1024;

/// A cloneable handle to the broadcast channel and the connection limiter,
/// shared through app state.
///
/// Presence and typing are ephemeral, in-memory-only state (see
/// `crate::presence` and `crate::typing`), and both need to be visible to
/// every connection the way the broadcast channel already is, so they live
/// here rather than as their own `AppState` fields.
#[derive(Clone)]
pub struct Hub {
    sender: broadcast::Sender<Event>,
    ephemeral_sender: broadcast::Sender<Event>,
    slots: Arc<Semaphore>,
    max_connections: usize,
    presence: PresenceTracker,
    typing: TypingTracker,
    ephemeral_budget: EphemeralBudget,
    permissions_epoch: Arc<AtomicU64>,
    blocks_epoch: Arc<AtomicU64>,
    idle_poll_interval: Duration,
    memory_guard: Arc<MemoryGuard>,
    moderation: Arc<ModerationClock>,
    handshake: handshake::Handshake,
    screen_consent: ScreenConsent,
}

/// Default value of [`Hub::idle_poll_interval`]: how often a live connection
/// checks whether its user just crossed the idle threshold, in either
/// direction, so the transition can be announced (see
/// `http::ws::signals::watch_idle`). Idle itself does not move this fast; it
/// only bounds how long an announcement can lag the real transition by.
const IDLE_POLL_INTERVAL: Duration = Duration::from_secs(30);

impl Default for Hub {
    fn default() -> Self {
        Self::new()
    }
}

impl Hub {
    pub fn new() -> Self {
        let (sender, _receiver) = broadcast::channel(CHANNEL_CAPACITY);
        let (ephemeral_sender, _ephemeral_receiver) =
            broadcast::channel(EPHEMERAL_CHANNEL_CAPACITY);
        Self {
            sender,
            ephemeral_sender,
            slots: Arc::new(Semaphore::new(MAX_CONNECTIONS)),
            max_connections: MAX_CONNECTIONS,
            presence: PresenceTracker::new(),
            typing: TypingTracker::new(),
            ephemeral_budget: EphemeralBudget::default(),
            permissions_epoch: Arc::new(AtomicU64::new(0)),
            blocks_epoch: Arc::new(AtomicU64::new(0)),
            idle_poll_interval: IDLE_POLL_INTERVAL,
            memory_guard: Arc::new(MemoryGuard::new()),
            moderation: Arc::new(ModerationClock::new()),
            handshake: handshake::Handshake::new(),
            screen_consent: ScreenConsent::default(),
        }
    }

    /// Builds a hub with a small connection ceiling, so a test can reach it with a few sockets.
    pub fn with_connection_limit(limit: usize) -> Self {
        Self {
            slots: Arc::new(Semaphore::new(limit)),
            max_connections: limit,
            ..Self::new()
        }
    }

    /// Builds a hub whose memory guard reads a caller-controlled reading
    /// instead of the real cgroup files, so a test can flip the guard from
    /// admitting to refusing without restarting anything or touching the
    /// real filesystem. See `tests/it_infra/memory_admission.rs`.
    pub fn with_memory_reading(shared: Arc<Mutex<MemoryReading>>) -> Self {
        Self {
            memory_guard: Arc::new(MemoryGuard::with_shared_reading(shared)),
            ..Self::new()
        }
    }

    /// Builds a hub with a non-default typing TTL, so a test can wait out the
    /// self-expiry in milliseconds instead of the production few seconds.
    ///
    /// Delegates rather than repeating the body, the way `TypingTracker`'s own
    /// pair already does: a field added to one and not the other is the whole
    /// failure mode of a duplicated constructor, and this hub has grown a
    /// field since the copy was made.
    pub fn with_typing_ttl(ttl: Duration) -> Self {
        Self {
            typing: TypingTracker::with_ttl(ttl),
            ..Self::new()
        }
    }

    /// Builds a hub with a non-default idle poll interval, so a test can
    /// observe an idle transition being announced in milliseconds instead of
    /// the production 30 seconds, without needing 10 real minutes to pass to
    /// reach the idle threshold itself (see `presence::PresenceTracker`'s own
    /// `_at` methods for how a test drives that half instead).
    pub fn with_idle_poll_interval(interval: Duration) -> Self {
        Self {
            idle_poll_interval: interval,
            ..Self::new()
        }
    }

    /// How often a live connection checks whether its user just crossed the
    /// idle threshold; see [`Self::with_idle_poll_interval`].
    pub fn idle_poll_interval(&self) -> Duration {
        self.idle_poll_interval
    }

    /// Publishes an event to every current subscriber, on the durable or the
    /// ephemeral channel according to [`is_ephemeral`]. Does nothing if there
    /// are no subscribers on that channel; never blocks or errors from the
    /// caller's point of view.
    pub fn publish(&self, event: Event) {
        let event = if is_moderation(&event) {
            Event::Stamped {
                seq: self.moderation.advance(),
                event: Box::new(event),
            }
        } else {
            event
        };
        // Bumped before the send, so no subscriber can act on a stale answer.
        if moves_permissions(&event) {
            self.permissions_epoch.fetch_add(1, Ordering::Release);
        }
        if is_ephemeral(&event) {
            let _ = self.ephemeral_sender.send(event);
        } else {
            let _ = self.sender.send(event);
        }
    }

    /// Events the slowest durable subscriber has not yet taken off the channel.
    pub fn durable_backlog(&self) -> usize {
        self.sender.len()
    }

    /// Connections and consumers currently subscribed to the durable channel.
    pub fn durable_subscribers(&self) -> usize {
        self.sender.receiver_count()
    }

    /// The number of the latest moderation event, for the connect `hello`; see
    /// `hub::moderation_seq`.
    pub fn moderation_head(&self) -> u64 {
        self.moderation.head()
    }

    /// A counter bumped whenever a published event means permissions moved.
    ///
    /// This exists so a cached permission answer can be invalidated by the
    /// *write*, not by the reader's place in the event stream. Delivery order
    /// across concurrent writers is best-effort (see this module's own note),
    /// so a connection can receive a `message.created` published by one
    /// request before the `overwrite.changed` published by another that
    /// already committed. A cache keyed on events alone would serve the
    /// pre-revocation answer for that message. Bumping a shared counter inside
    /// `publish`, before the send, makes the invalidation immediate and global
    /// instead, and leaves only the gap between a handler's commit and its
    /// publish call - which carries no await in any handler that publishes one
    /// of these.
    pub fn permissions_epoch(&self) -> u64 {
        self.permissions_epoch.load(Ordering::Acquire)
    }

    /// Moves whenever anyone's block list changes, so a connection's cached
    /// block list is read again; see `http::ws::permission_cache`.
    pub fn blocks_epoch(&self) -> u64 {
        self.blocks_epoch.load(Ordering::Acquire)
    }

    /// Called by the block and unblock handlers once the change has committed.
    pub fn blocks_changed(&self) {
        self.blocks_epoch.fetch_add(1, Ordering::Release);
    }

    /// Subscribes a new connection to the durable event stream: messages,
    /// channel/role/presence changes, and durable canvas state. A subscriber
    /// that falls behind on this channel is expected to resync; see
    /// [`Self::subscribe_ephemeral`] for the channel where that is not true.
    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.sender.subscribe()
    }

    /// Subscribes a new connection to the ephemeral event stream: live canvas
    /// cursor and stroke-preview frames. A subscriber that falls behind here
    /// must skip forward and keep running rather than resync - see this
    /// module's own doc comment.
    pub fn subscribe_ephemeral(&self) -> broadcast::Receiver<Event> {
        self.ephemeral_sender.subscribe()
    }

    /// Claims a connection slot, or `None` if the ceiling is reached. The permit
    /// is held for the connection's lifetime and releases the slot when dropped.
    pub fn try_connect(&self) -> Option<OwnedSemaphorePermit> {
        self.slots.clone().try_acquire_owned().ok()
    }

    /// How many WebSocket connections are open right now, for `/metrics`.
    /// Derived from the semaphore's own remaining permits rather than a
    /// second counter, so it cannot drift from what actually gates a connect.
    pub fn connection_count(&self) -> usize {
        self.max_connections - self.slots.available_permits()
    }

    /// Whether the memory guard admits a new connection right now; see
    /// `hub::memory_guard`'s own doc comment. Only gates admission - never
    /// disturbs a connection already open.
    pub fn admit_memory(&self) -> bool {
        self.memory_guard.admit()
    }

    /// The memory guard's own view of the ceiling, current usage, and
    /// refusal count, for `/metrics`.
    pub fn memory_admission_snapshot(&self) -> MemoryAdmissionSnapshot {
        self.memory_guard.snapshot()
    }

    /// The shared, cloneable presence tracker (a cheap `Arc` clone).
    pub fn presence(&self) -> PresenceTracker {
        self.presence.clone()
    }

    /// Each sharer's last relayed drawing consent, which the stamp route checks.
    pub fn screen_consent(&self) -> &ScreenConsent {
        &self.screen_consent
    }

    /// The shared, cloneable typing tracker (a cheap `Arc` clone).
    pub fn typing(&self) -> TypingTracker {
        self.typing.clone()
    }

    /// How many private messages each bot has spent per anchor.
    pub fn ephemeral_budget(&self) -> EphemeralBudget {
        self.ephemeral_budget.clone()
    }
}

#[cfg(test)]
mod epoch_tests;

#[cfg(test)]
mod connection_count_tests;

#[cfg(test)]
mod event_size_tests;
