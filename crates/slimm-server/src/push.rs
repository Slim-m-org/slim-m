// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Push notification triggering: turns a new message into (at most) one wake
//! per idle recipient, without ever slowing down or failing the send that
//! triggered it.
//!
//! What that wake carries is [`envelope`]'s subject, and the short version is
//! that the relay can read none of it either way: a device that asked for
//! message content gets a preview sealed to its own key, and every other
//! device gets the same content-free envelope it always did.
//!
//! [`PushSender`] is deliberately a first-class two-state thing rather than an
//! error path. `SLIMM_PUSH_RELAY_URL` and `SLIMM_PUSH_RELAY_KEY` are both
//! optional; a LAN-only or NAT-unreachable self-host has nowhere for a relay
//! to reach it, and that is a fully supported deployment, so an unconfigured
//! sender is a quiet no-op, not a startup failure. When a relay URL is
//! configured, its scheme is checked once here at startup
//! (`crate::sidecar_url::validate`): `http://` leaks every recipient's push
//! token and the relay bearer key in cleartext, so it is refused unless the
//! relay is loopback or private-range, where nothing to leak to ever leaves
//! the LAN.
//!
//! Triggering reads the client-reported lifecycle state, never raw WebSocket
//! presence: iOS suspends a socket without closing it, so a live connection is
//! not proof the app can show anything. A short debounce, keyed per
//! `(channel, recipient)` and evaluated only after lifecycle filtering,
//! collapses a burst of messages to one recipient into one wake instead of one
//! push per message, without one recipient's suppressed window ever silencing
//! a different recipient. A window that turns out to have delivered nobody
//! anything (a relay error, or a stored key too corrupt to seal to) is
//! released rather than left spent, so it collapses a burst instead of
//! dropping the next message's wake outright; see [`Debounce`].
//!
//! [`PushSender::notify_message`] is called synchronously from the message
//! send handler but does no I/O itself: it makes a cheap in-memory decision
//! (is push even enabled?) and, if so, hands everything else, including the
//! debounce, to a detached [`tokio::spawn`]ed task. The message is already
//! committed and its response already on the way back to the caller, so
//! nothing here can turn a successful send into an error, and nothing here can
//! make it slower.

mod attention;
mod call_end;
mod call_ring;
mod debounce;
mod deliver;
mod dispatch;
mod envelope;
mod mention_grammar;
// pub(crate): crate::mentions reuses resolved_mentions directly rather than reimplementing it.
mod preview_text;
pub(crate) mod recipients;
mod relay;
mod sealing;
mod security;

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::config::Config;
use crate::ids::{CallRingId, ChannelId, MessageId, Seq, UserId};
use crate::presence::PresenceTracker;
use crate::store::Store;

use debounce::Debounce;

pub use attention::narrow_for_attention;
pub use recipients::message_recipients;
pub use security::NewDeviceSignIn;

/// How long a burst of messages in one channel collapses into a single wake.
/// Leading-edge: the first message in a burst fires immediately and the rest
/// are suppressed until the window elapses, rather than waiting out a
/// trailing quiet period before anyone is notified.
const DEFAULT_DEBOUNCE_WINDOW_MS: i64 = 10_000;

/// Triggers push for new messages. Cheap to clone (an `Option<Arc<_>>` plus an
/// `Arc<Debounce>`), so it lives directly on [`crate::http::AppState`].
#[derive(Clone)]
pub struct PushSender {
    inner: Option<Arc<Enabled>>,
    debounce: Arc<Debounce>,
}

struct Enabled {
    http: reqwest::Client,
    send_url: String,
    key: String,
    /// Messages the relay refused as `forbidden` since start, i.e. a device it will not
    /// deliver to for this server's key.
    forbidden: AtomicU64,
}

impl PushSender {
    /// Builds a sender from the process config. Disabled, quietly and
    /// permanently for this process's life, unless both the relay URL and key
    /// are set; logs that decision once, here, at startup. Fails if a relay
    /// URL is set but its scheme is not safe to use (see
    /// [`validate_relay_url`]), so a misconfigured deployment refuses to start
    /// rather than leaking silently the first time it sends a push.
    pub fn new(config: &Config) -> anyhow::Result<Self> {
        Self::with_debounce_window_ms(config, DEFAULT_DEBOUNCE_WINDOW_MS)
    }

    /// [`Self::new`] with an explicit debounce window, so tests can exercise
    /// collapsing (and its expiry) without waiting out the real window.
    ///
    /// Redirects are refused rather than followed. reqwest strips sensitive
    /// headers across a redirect only when the host or port changes, comparing
    /// neither the scheme, so an https to http downgrade back to the same host
    /// would carry the relay bearer key and every device push token in it. The
    /// relay is a known endpoint we configure, so it has no business
    /// redirecting.
    pub fn with_debounce_window_ms(config: &Config, window_ms: i64) -> anyhow::Result<Self> {
        let inner = match (&config.push_relay_url, &config.push_relay_key) {
            (Some(url), Some(key)) => {
                crate::sidecar_url::validate(url, "SLIMM_PUSH_RELAY_URL")?;
                // Redirects refused, not followed; see the note on this
                // function.
                let http = reqwest::Client::builder()
                    .timeout(relay::RELAY_TIMEOUT)
                    .redirect(reqwest::redirect::Policy::none())
                    .build()
                    .expect("building the push relay HTTP client");
                Some(Arc::new(Enabled {
                    http,
                    send_url: format!("{}/v1/send", url.trim_end_matches('/')),
                    key: key.clone(),
                    forbidden: AtomicU64::new(0),
                }))
            }
            _ => {
                tracing::info!(
                    "SLIMM_PUSH_RELAY_URL / SLIMM_PUSH_RELAY_KEY not set; push notifications are disabled"
                );
                None
            }
        };
        Ok(Self {
            inner,
            debounce: Arc::new(Debounce::new(window_ms)),
        })
    }

    /// A sender that never reaches a relay. Distinct from a misconfigured
    /// [`Self::new`] only in that it never logs: it is the explicit choice a
    /// caller (mainly tests) makes, not the outcome of missing config.
    pub fn disabled() -> Self {
        Self {
            inner: None,
            debounce: Arc::new(Debounce::new(DEFAULT_DEBOUNCE_WINDOW_MS)),
        }
    }

    /// How many messages the relay has refused as `forbidden` since start; always zero for a
    /// disabled sender.
    pub fn relay_forbidden_total(&self) -> u64 {
        self.inner
            .as_ref()
            .map_or(0, |enabled| enabled.forbidden.load(Ordering::Relaxed))
    }

    /// Whether this sender will actually reach a relay.
    pub fn is_enabled(&self) -> bool {
        self.inner.is_some()
    }

    /// Considers pushing a wake for a message that was just committed.
    ///
    /// Synchronous and cheap: a disabled sender returns immediately without
    /// touching the database or the network. Otherwise the recipient lookup,
    /// lifecycle gating, per-recipient debounce, sealing, and relay call all
    /// happen in a detached background task, so this never blocks or fails
    /// the caller. The debounce is not decided here: it needs to know who the
    /// recipients are first, so it is evaluated inside that task instead (see
    /// [`Debounce`]).
    pub fn notify_message(&self, store: Store, sent: SentMessage) {
        let Some(enabled) = self.inner.clone() else {
            return;
        };
        tokio::spawn(deliver::deliver(
            enabled,
            self.debounce.clone(),
            store,
            sent,
        ));
    }

    /// Considers pushing a wake for a DM call ring that was just started.
    ///
    /// The same synchronous-and-cheap shape [`Self::notify_message`] already
    /// has: a disabled sender returns immediately, and everything else -
    /// the preference check, the lookup, sealing, and the relay call - runs
    /// in a detached background task so this never blocks the `ring` route's
    /// own response. No debounce: see `call_ring`'s own module doc for why a
    /// ring never needs one.
    pub fn notify_call_ring(
        &self,
        store: Store,
        channel_id: ChannelId,
        ring_id: CallRingId,
        caller_id: UserId,
        callee_id: UserId,
    ) {
        let Some(enabled) = self.inner.clone() else {
            return;
        };
        tokio::spawn(call_ring::deliver(
            enabled, store, channel_id, ring_id, caller_id, callee_id,
        ));
    }

    /// Tells the callee's devices a ring ended, whatever ended it, so none keeps ringing.
    pub fn notify_call_end(
        &self,
        store: Store,
        channel_id: ChannelId,
        ring_id: CallRingId,
        caller_id: UserId,
    ) {
        let Some(enabled) = self.inner.clone() else {
            return;
        };
        tokio::spawn(call_end::deliver(
            enabled, store, channel_id, ring_id, caller_id,
        ));
    }

    /// Alerts an account's other devices that a device it has not used before signed in.
    pub fn notify_new_device_sign_in(&self, store: Store, sign_in: NewDeviceSignIn) {
        let Some(enabled) = self.inner.clone() else {
            return;
        };
        tokio::spawn(security::deliver(enabled, store, sign_in));
    }
}

/// What [`PushSender::notify_message`] needs to know about a message that was
/// just committed, bundled rather than five positional arguments.
///
/// `content` is read to resolve `@`-mentions for [`message_recipients`]'s
/// thread narrowing, and, for a device that asked for it, to build the preview
/// sealed inside that device's own envelope. It is never put on the wire in a
/// form the relay can read: a preview only ever exists inside the sealed box,
/// which is why this is a per-device choice at all rather than a deployment
/// one. See [`envelope`]'s module docs.
pub struct SentMessage {
    pub channel_id: ChannelId,
    pub author_id: UserId,
    pub message_id: MessageId,
    pub seq: Seq,
    pub content: String,
    pub presence: PresenceTracker,
    /// The replied-to author a reply chose to ping; pushed as a mention.
    pub reply_ping: Option<UserId>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_sender_reports_disabled() {
        assert!(!PushSender::disabled().is_enabled());
    }

    // The URL-scheme rules themselves (https always fine, http only for a
    // loopback/private host) are `sidecar_url`'s own tests; this file only
    // proves `PushSender` actually wires that check in below.

    #[test]
    fn with_debounce_window_ms_rejects_a_cleartext_public_relay() {
        let config = Config {
            port: 0,
            database_path: String::new(),
            hash_concurrency: 1,
            push_relay_url: Some("http://relay.example.com".to_owned()),
            push_relay_key: Some("key".to_owned()),
            ..Config::default()
        };
        assert!(
            PushSender::with_debounce_window_ms(&config, 1_000).is_err(),
            "a cleartext relay over the public internet must fail loudly at startup"
        );
    }
}
