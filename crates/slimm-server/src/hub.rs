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

mod event;
mod memory_guard;
mod moderation_seq;
pub use event::Event;
use memory_guard::MemoryGuard;
pub use memory_guard::{MemoryAdmissionSnapshot, MemoryReading};
use moderation_seq::{ModerationClock, is_moderation};

/// How many events the durable channel buffers per subscriber before the
/// slowest one starts losing the oldest and receives a `Lagged` error.
/// Referenced from [`Event`]'s own doc comments, in `hub/event.rs`, as the
/// bound a canvas frame is sized against.
pub(crate) const CHANNEL_CAPACITY: usize = 1024;

/// How many events the ephemeral channel buffers per subscriber before the
/// slowest one starts losing the oldest.
///
/// Sized against the two event classes it carries, both rate-limited (see
/// `crate::ratelimit::Class::CanvasCursor` and `::CanvasStrokePreview`):
/// `CanvasCursorMoved` sustains at most 15/sec/drawer, and a stroke preview is
/// metered by bytes rather than count but a well-behaved client flushes on the
/// order of once per animation frame, so it never dominates. A phone
/// backgrounded during an active canvas session with, say, 4 other drawers
/// each cursoring at the full 15/sec rate produces 60 events/sec; 512 gives
/// that roughly 8.5 seconds of buffer before the *oldest* (never the newest,
/// see `Class::CanvasCursor`'s own budget) frame is dropped - and dropping
/// here costs nothing more than a slightly stale cursor, never a resync.
pub(crate) const EPHEMERAL_CHANNEL_CAPACITY: usize = 512;

/// Ceiling on simultaneously open WebSocket connections.
const MAX_CONNECTIONS: usize = 1024;

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
    presence: PresenceTracker,
    typing: TypingTracker,
    ephemeral_budget: EphemeralBudget,
    permissions_epoch: Arc<AtomicU64>,
    idle_poll_interval: Duration,
    memory_guard: Arc<MemoryGuard>,
    moderation: Arc<ModerationClock>,
}

/// Default value of [`Hub::idle_poll_interval`]: how often a live connection
/// checks whether its user just crossed the idle threshold, in either
/// direction, so the transition can be announced (see
/// `http::ws::signals::watch_idle`). Idle itself does not move this fast; it
/// only bounds how long an announcement can lag the real transition by.
const IDLE_POLL_INTERVAL: Duration = Duration::from_secs(30);

/// Whether this event means somebody's permissions may have moved.
///
/// Exhaustive on purpose: a new variant does not compile until somebody
/// decides, and the safe answer for anything permission-shaped is `true`.
/// Over-reporting only costs a re-derivation; under-reporting is a stale
/// answer served to a caller who should no longer have it.
fn moves_permissions(event: &Event) -> bool {
    match event {
        Event::RoleChanged { .. }
        | Event::MemberRoleChanged { .. }
        | Event::MemberTimeoutChanged { .. }
        | Event::MemberRemoved(_)
        | Event::MemberRestored(_)
        | Event::OverwriteChanged { .. }
        | Event::ChannelCreated(..)
        | Event::ChannelUpdated(..)
        | Event::ChannelDeleted { .. } => true,
        Event::MessageCreated { .. }
        | Event::MessageEdited { .. }
        | Event::MessageDeleted { .. }
        | Event::ReactionsChanged { .. }
        | Event::CodeRunChanged { .. }
        | Event::CodeRunsCleared { .. }
        | Event::ThreadUpdated { .. }
        | Event::MessagePinned { .. }
        | Event::MessageUnpinned { .. }
        | Event::PollVoted { .. }
        | Event::MessageComponentsChanged { .. }
        | Event::TypingStarted { .. }
        | Event::TypingStopped { .. }
        | Event::PresenceChanged(_)
        | Event::ProfileChanged(_)
        | Event::BotUiChanged(_)
        | Event::CanvasObjectPlaced { .. }
        | Event::CanvasObjectsRemoved { .. }
        | Event::CanvasCleared { .. }
        | Event::CanvasObjectsRestored { .. }
        | Event::CanvasCursorMoved { .. }
        | Event::CanvasStrokePreview { .. }
        | Event::CanvasObjectMoved { .. }
        | Event::CanvasObjectReordered { .. }
        | Event::CanvasMediaSlotChanged { .. }
        | Event::SessionRevoked(_)
        // A join changes nobody's existing cached answer; see the variant's own doc.
        | Event::MemberJoined(_)
        // Who is on a call changes no permission's answer.
        | Event::VoiceActivityChanged { .. }
        | Event::VoiceParticipantJoined { .. }
        | Event::VoiceParticipantLeft { .. }
        | Event::VoiceScreenShareChanged { .. }
        | Event::WatchTick { .. }
        // Ringing, and how a ring ended, changes no permission's answer either.
        | Event::CallRinging { .. }
        | Event::CallRingEnded { .. }
        // A category grants and denies nothing (docs/decisions/0006).
        | Event::CategoryChanged
        // A report being filed or resolved changes no permission's answer either.
        | Event::ReportsChanged
        // Private notices and read markers move no permission and need no fan-out ordering.
        | Event::ReadStateChanged { .. }
        | Event::NotificationOverrideChanged { .. }
        | Event::EphemeralMessage { .. }
        | Event::InteractionCreated { .. }
        | Event::InteractionAnswered { .. }
        | Event::NewDeviceSignIn { .. } => false,
        Event::Stamped { event, .. } => moves_permissions(event),
    }
}

/// Whether this event belongs on the ephemeral channel rather than the
/// durable one - see this module's own doc comment for what that split means.
///
/// Exhaustive on purpose, the same discipline [`moves_permissions`] already
/// uses: a new variant does not compile until somebody decides which channel
/// it fans out on, and the safe default is durable, not ephemeral, since a
/// dropped durable event is a much larger surprise than a slightly stale
/// cursor.
///
/// [`Event::EphemeralMessage`] rides here too, being unnumbered and never
/// stored, at a rate a bot's write limit keeps far below the cursors'.
/// Otherwise only [`Event::CanvasCursorMoved`] and [`Event::CanvasStrokePreview`]
/// qualify: both are rate-limited well above what a human notices, carry no
/// `seq`, are never persisted, and have no catch-up path a reconnect could use
/// anyway (see their own doc comments in `hub/event.rs`). `TypingStarted`/
/// `TypingStopped` are ephemeral in the same sense but stay durable here: they
/// are rate-limited far lower (`Class::Typing`: 2/sec sustained against
/// `CanvasCursor`'s 15/sec), they come in explicit start/stop pairs rather
/// than a stream a receiver ages out on its own, and a dropped `Stopped` on a
/// lossy channel would leave a "someone is typing" indicator stuck until the
/// next unrelated typing refresh from that user - worse than the bounded
/// staleness a lost cursor produces. Moving them costs a decision with a real
/// downside for a rate that page rarely approaches the durable channel's own
/// capacity in the first place.
fn is_ephemeral(event: &Event) -> bool {
    match event {
        Event::CanvasCursorMoved { .. }
        | Event::CanvasStrokePreview { .. }
        | Event::WatchTick { .. }
        | Event::EphemeralMessage { .. }
        | Event::InteractionCreated { .. }
        | Event::InteractionAnswered { .. } => true,
        Event::MessageCreated { .. }
        | Event::MessageEdited { .. }
        | Event::MessageDeleted { .. }
        | Event::ReactionsChanged { .. }
        | Event::CodeRunChanged { .. }
        | Event::CodeRunsCleared { .. }
        | Event::ThreadUpdated { .. }
        | Event::MessagePinned { .. }
        | Event::MessageUnpinned { .. }
        | Event::PollVoted { .. }
        | Event::MessageComponentsChanged { .. }
        | Event::TypingStarted { .. }
        | Event::TypingStopped { .. }
        | Event::PresenceChanged(_)
        | Event::ProfileChanged(_)
        | Event::BotUiChanged(_)
        | Event::RoleChanged { .. }
        | Event::MemberRoleChanged { .. }
        | Event::MemberTimeoutChanged { .. }
        | Event::MemberRemoved(_)
        | Event::MemberRestored(_)
        | Event::MemberJoined(_)
        | Event::OverwriteChanged { .. }
        | Event::ChannelCreated(..)
        | Event::ChannelUpdated(..)
        | Event::ChannelDeleted { .. }
        | Event::CategoryChanged
        | Event::CanvasObjectPlaced { .. }
        | Event::CanvasObjectsRemoved { .. }
        | Event::CanvasCleared { .. }
        | Event::CanvasObjectsRestored { .. }
        | Event::CanvasObjectMoved { .. }
        | Event::CanvasObjectReordered { .. }
        | Event::CanvasMediaSlotChanged { .. }
        | Event::SessionRevoked(_)
        | Event::VoiceActivityChanged { .. }
        | Event::VoiceParticipantJoined { .. }
        | Event::VoiceParticipantLeft { .. }
        | Event::VoiceScreenShareChanged { .. }
        | Event::CallRinging { .. }
        | Event::CallRingEnded { .. }
        | Event::ReportsChanged
        // Private notices and read markers move no permission and need no fan-out ordering.
        | Event::ReadStateChanged { .. }
        | Event::NotificationOverrideChanged { .. }
        | Event::NewDeviceSignIn { .. } => false,
        Event::Stamped { event, .. } => is_ephemeral(event),
    }
}

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
            presence: PresenceTracker::new(),
            typing: TypingTracker::new(),
            ephemeral_budget: EphemeralBudget::default(),
            permissions_epoch: Arc::new(AtomicU64::new(0)),
            idle_poll_interval: IDLE_POLL_INTERVAL,
            memory_guard: Arc::new(MemoryGuard::new()),
            moderation: Arc::new(ModerationClock::new()),
        }
    }

    /// Builds a hub whose memory guard reads a caller-controlled reading
    /// instead of the real cgroup files, so a test can flip the guard from
    /// admitting to refusing without restarting anything or touching the
    /// real filesystem. See `tests/memory_admission.rs`.
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
        MAX_CONNECTIONS - self.slots.available_permits()
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
mod epoch_tests {
    use super::*;
    use crate::ids::{ChannelId, RoleId, UserId};

    /// The property the view cache rests on: the counter moves inside
    /// `publish`, so it has already moved by the time anybody could receive
    /// the event - and for a subscriber that never receives it at all.
    ///
    /// That is the whole difference from invalidating as events arrive. A
    /// connection lagging behind its queue would otherwise keep serving a
    /// pre-revocation answer for every event still ahead of the revocation in
    /// its own backlog, however long ago the write committed.
    #[test]
    fn the_epoch_moves_before_any_subscriber_receives() {
        let hub = Hub::new();
        let mut rx = hub.subscribe();
        let before = hub.permissions_epoch();

        hub.publish(Event::OverwriteChanged {
            channel_id: ChannelId::generate(),
            previously_visible_to: Vec::new(),
        });

        assert!(
            hub.permissions_epoch() > before,
            "the epoch must move without anybody having read the event yet",
        );
        assert!(rx.try_recv().is_ok(), "and the event is still delivered");
    }

    /// A clone is what every handler holds, so an epoch that did not travel
    /// with it would move for nobody.
    #[test]
    fn a_clone_shares_the_same_counter() {
        let hub = Hub::new();
        let handle = hub.clone();
        let before = hub.permissions_epoch();
        handle.publish(Event::MemberRemoved(UserId::generate()));
        assert!(hub.permissions_epoch() > before);
    }

    /// Ordinary traffic must not move it, or the cache never holds anything
    /// and the whole change is a no-op with extra steps.
    #[test]
    fn channel_traffic_leaves_it_alone() {
        let hub = Hub::new();
        let before = hub.permissions_epoch();
        hub.publish(Event::TypingStarted {
            channel_id: ChannelId::generate(),
            user_id: UserId::generate(),
        });
        hub.publish(Event::PresenceChanged(UserId::generate()));
        hub.publish(Event::MessageDeleted {
            op_seq: None,
            channel_id: ChannelId::generate(),
            message_id: crate::ids::MessageId::generate(),
        });
        hub.publish(Event::VoiceActivityChanged {
            channel_id: ChannelId::generate(),
        });
        hub.publish(Event::MemberJoined(UserId::generate()));
        hub.publish(Event::CanvasCursorMoved {
            channel_id: ChannelId::generate(),
            user_id: UserId::generate(),
            x: 0.0,
            y: 0.0,
        });
        hub.publish(Event::CanvasStrokePreview {
            channel_id: ChannelId::generate(),
            user_id: UserId::generate(),
            object_id: crate::ids::CanvasObjectId::generate(),
            points: vec![0.0, 0.0],
            ended: false,
        });
        assert_eq!(hub.permissions_epoch(), before);
    }

    #[test]
    fn every_permission_shaped_event_moves_it() {
        let hub = Hub::new();
        for event in [
            Event::RoleChanged {
                role_id: RoleId::generate(),
            },
            Event::MemberRoleChanged {
                user_id: UserId::generate(),
                role_id: RoleId::generate(),
            },
            Event::MemberTimeoutChanged {
                user_id: UserId::generate(),
                until: Some(1),
            },
            Event::MemberRemoved(UserId::generate()),
            Event::ChannelDeleted {
                channel_id: ChannelId::generate(),
            },
        ] {
            let before = hub.permissions_epoch();
            hub.publish(event);
            assert!(hub.permissions_epoch() > before);
        }
    }
}

#[cfg(test)]
mod connection_count_tests;
