// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Presence and typing glue for one WebSocket connection: the connect and
//! disconnect bookkeeping presence needs, and the inbound typing-frame
//! handling. Split out of `super` (the envelope and connection loop) so that
//! file stays focused on the wire protocol itself.

use super::frames::ServerFrame;
use crate::hub::{Event, Hub};
use crate::ids::{ChannelId, DeviceId, UserId};
use crate::permissions::Permissions;
use crate::presence::{self, DeviceKind, Status, Visibility};
use crate::ratelimit::{Class, RateLimiter};
use crate::store::{SessionContext, Store};

/// Ensures a disconnect is always recorded and published, no matter which
/// branch of the read loop in `super::serve` causes it to return: a `Drop`
/// impl runs on every exit path, including an early `return` or a panic
/// unwind, the way an explicit call at the bottom of the function could not.
pub(super) struct PresenceGuard {
    hub: Hub,
    user_id: UserId,
    device_id: DeviceId,
    kind: DeviceKind,
    connection: u64,
    idle_watch: tokio::task::AbortHandle,
}

impl PresenceGuard {
    /// Records a new live connection for `user_id` and publishes a change if
    /// this is their first (see [`crate::presence::PresenceTracker::connect`]).
    /// The returned guard must be held for the connection's whole lifetime.
    pub(super) async fn connect(
        hub: Hub,
        store: Store,
        user_id: UserId,
        device_id: DeviceId,
        active: bool,
    ) -> Self {
        let kind = store.device_kind(device_id).await;
        let first = hub.presence().connect_as(user_id, kind, active);
        // Fill the cache without clobbering a concurrent visibility change (see load_visibility).
        if let Ok(Some(visibility)) = store.presence_visibility(user_id).await {
            hub.presence().load_visibility(user_id, visibility);
        }
        if first {
            hub.publish(Event::PresenceChanged(user_id));
        }
        let idle_watch = tokio::spawn(watch_idle(hub.clone(), store, user_id)).abort_handle();
        let connection = hub.presence().viewing().new_connection();
        Self {
            hub,
            user_id,
            device_id,
            kind,
            connection,
            idle_watch,
        }
    }

    /// Records which channels this connection reports as open and focused.
    ///
    /// Unparseable ids are skipped and the list is capped: it only ever
    /// shortens this account's own push, so a bad frame costs nothing else.
    pub(super) fn set_viewing(&self, channel_ids: &[String], active: bool) {
        let channels = channel_ids
            .iter()
            .take(crate::viewing::MAX_VIEWED_CHANNELS)
            .filter_map(|raw| uuid::Uuid::parse_str(raw).ok())
            .map(ChannelId)
            .collect();
        let viewing = self.hub.presence().viewing();
        viewing.set(self.user_id, self.device_id, self.connection, channels);
        if active {
            viewing.mark_active(self.user_id, self.device_id, self.connection);
        }
    }
}

impl Drop for PresenceGuard {
    fn drop(&mut self) {
        self.idle_watch.abort();
        self.hub
            .presence()
            .viewing()
            .forget_connection(self.user_id, self.connection);
        if self.hub.presence().disconnect_as(self.user_id, self.kind) {
            self.hub.publish(Event::PresenceChanged(self.user_id));
        }
    }
}

/// Announces `user_id` crossing the idle threshold, in either direction.
///
/// Idle is purely a function of elapsed time against `PresenceTracker`'s
/// clock, not an event anything publishes on its own, so nothing would ever
/// tell a live viewer it happened otherwise: a connection that goes quiet
/// would read as online forever to everyone already watching, until some
/// unrelated event happened to touch this user's row again. Runs for the
/// connection's whole lifetime and is aborted by `PresenceGuard`'s `Drop`.
///
/// A user with several live connections runs one of these per connection,
/// all polling the one shared idle clock those connections share; a
/// transition can be published more than once for the same instant, which
/// costs one `presence_visibility` lookup plus a re-derivation per receiving
/// connection, the same trade `Hub::publish`'s own callers accept elsewhere.
///
/// **Published only for [`Visibility::Online`], and that is a privacy
/// property rather than an optimisation.** [`presence::status_for`] ignores
/// `idle` entirely for the other three, so a frame here would carry no
/// information any viewer is allowed to act on - but it would still be a
/// frame, arriving exactly when a user who chose to appear offline went quiet
/// and again when they came back. An observer timestamping frames learns
/// their activity pattern from that alone, however correct the derived status
/// is. Publishing on connect and disconnect is a narrower version of the same
/// thing and predates this; widening it to every idle transition is what this
/// avoids.
async fn watch_idle(hub: Hub, store: Store, user_id: UserId) {
    let mut ticks = tokio::time::interval(hub.idle_poll_interval());
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut idle = false;
    loop {
        ticks.tick().await;
        let now_idle = hub.presence().is_idle(user_id);
        if now_idle == idle {
            continue;
        }
        idle = now_idle;
        // Read per transition, not once: visibility can change mid-connection.
        if matches!(
            store.presence_visibility(user_id).await,
            Ok(Some(Visibility::Online))
        ) {
            hub.publish(Event::PresenceChanged(user_id));
        }
    }
}

/// Resolves what `viewer` may be told about `target`'s live presence.
///
/// `Ok(None)` only if `target`'s account is gone: a fan-out racing an account
/// deletion should not synthesize presence for it. `Err` means the store
/// could not answer at all, and is kept distinct from `Ok(None)` on purpose:
/// a caller with something to protect (see `authorize`'s typing branch in
/// `super`) must be able to fail closed on a blip without that blip reading
/// as an ordinary "account gone" answer.
pub(super) async fn presence_status(
    store: &Store,
    hub: &Hub,
    viewer: UserId,
    target: UserId,
) -> anyhow::Result<Option<Status>> {
    let tracker = hub.presence();
    // Prefer the cache; a miss falls back to the exact store query this always made (its `None` still means a gone account).
    let visibility = match tracker.visibility(target) {
        Some(cached) => cached,
        None => match store.presence_visibility(target).await? {
            Some(visibility) => visibility,
            None => return Ok(None),
        },
    };
    Ok(Some(presence::status_for(
        viewer,
        target,
        visibility,
        tracker.is_connected(target),
        tracker.is_idle(target),
    )))
}

/// Whether `viewer` may be told that `target`'s typing ended.
///
/// Unlike the start, the stop is published by a timer that can fire after the
/// typer disconnected, when they read as offline to everyone; withholding it
/// then strands the indicator on every other client. Only a typer who chose
/// to appear offline stays withheld (their start was never announced), and a
/// store error fails closed as it does for the start.
pub(super) async fn may_hear_typing_stop(
    store: &Store,
    hub: &Hub,
    viewer: UserId,
    target: UserId,
) -> bool {
    if viewer == target {
        return true;
    }
    let visibility = match hub.presence().visibility(target) {
        Some(cached) => cached,
        None => match store.presence_visibility(target).await {
            Ok(Some(visibility)) => visibility,
            _ => return false,
        },
    };
    visibility != Visibility::Hidden
}

/// The frame telling a viewer `target`'s resolved status, and the activity
/// that status permits them to see.
pub(super) fn presence_frame(hub: &Hub, target: UserId, status: Status) -> ServerFrame {
    ServerFrame::PresenceChanged {
        user_id: target.to_string(),
        status: status.as_str().to_owned(),
        activity: hub.presence().activity_visible_at(target, status),
        devices: hub.presence().device_names_visible_at(target, status),
    }
}

/// Accepts a typing refresh from `ctx`'s user for `channel_id`, if the rate
/// limiter and channel permissions allow it. Silent on every rejection:
/// typing is a low-stakes hint, not worth an error frame or closing the
/// socket over.
///
/// The permission bar is the same one a send would have to clear: viewing is
/// required so this cannot probe for a channel's existence, and sending is
/// required so a read-only member cannot show up as "about to post" somewhere
/// they could not.
pub(super) async fn handle_typing(
    store: &Store,
    hub: &Hub,
    limiter: &RateLimiter,
    ctx: &SessionContext,
    channel_id: &str,
) {
    let Ok(channel_id) = uuid::Uuid::parse_str(channel_id) else {
        return;
    };
    let channel_id = ChannelId(channel_id);

    if !limiter.check(Class::Typing, &format!("u:{}", ctx.user_id)) {
        return;
    }

    // Behind the limiter, so a typing flood cannot hammer the shared presence lock.
    hub.presence().touch(ctx.user_id);

    // Same bar a send would clear; see the note on this function.
    let needed = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    match store.has_permission(ctx.user_id, channel_id, needed).await {
        Ok(true) => {}
        _ => return,
    }

    let (generation, is_new) = hub.typing().start(channel_id, ctx.user_id);
    if is_new {
        hub.publish(Event::TypingStarted {
            channel_id,
            user_id: ctx.user_id,
        });
    }

    // Self-expiry, one per refresh and a no-op once a later refresh bumps the
    // generation past this one (`crate::typing::TypingTracker::expire`).
    let hub = hub.clone();
    let ttl = hub.typing().ttl();
    let user_id = ctx.user_id;
    tokio::spawn(async move {
        tokio::time::sleep(ttl).await;
        if hub.typing().expire(channel_id, user_id, generation) {
            hub.publish(Event::TypingStopped {
                channel_id,
                user_id,
            });
        }
    });
}
