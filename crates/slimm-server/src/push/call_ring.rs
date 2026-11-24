// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Waking a backgrounded phone for an incoming DM call ring.
//!
//! [`deliver`] mirrors `deliver.rs`'s message path trimmed to what a ring
//! actually needs: exactly one recipient, and no debounce - a ring fires once
//! per attempt, never in the kind of burst a message send can produce, so
//! there is nothing here for a debounce window to collapse.
//!
//! The envelope shares [`envelope::seal_for_message`]'s sealing machinery
//! (the domain, version, byte budget and per-target key handling all live in
//! `envelope.rs`) but not its content-free/with-content split for a *body*:
//! a ring carries no message text, only who is calling. [`CallRingEnvelope`]
//! is this module's own shape for that: `channel_id`, `ring_id` and
//! `caller_id` ride unconditionally (a receiving device could already
//! resolve who is calling from `channel_id` alone, since a DM has exactly
//! one other participant), while `caller_name` is gated behind
//! [`PushTarget::include_content`] exactly as a message's own sender name is.
//!
//! The notification schedule (`notification_schedule.rs`, decision
//! docs/decisions/0033-notification-schedule.md) is not consulted here
//! either, deliberately, in both its off-hours modes: a direct call is at
//! least as addressed-to-you as an ordinary DM message, so neither
//! `mentions`-and-DMs off hours nor `nothing` off hours mutes a ring - the
//! one Slack-style exception this schedule makes. The one preference that
//! does suppress a ring is [`NotificationPreference::Nothing`]: an account
//! that opted out of every notification, DMs included, also opted out of
//! being rung. Do not disturb never reaches here: the ring route leaves those
//! callees out before anything is sent.

use std::sync::Arc;

use serde::Serialize;

use crate::ids::{CallRingId, ChannelId, UserId};
use crate::notifications::NotificationPreference;
use crate::store::{Store, now_ms};

use super::deliver::is_foreground_and_recent;
use super::envelope::{
    DOMAIN, ENVELOPE_VERSION, MAX_ENVELOPE_PLAINTEXT_BYTES, MAX_PREVIEW_NAME_CHARS, PushKind,
    SealedMessage, truncate,
};
use super::sealing::{TokenSlot, seal_to};
use super::{Enabled, dispatch};

/// Delivers a push for one DM call ring to its one callee.
///
/// Every error path logs and returns rather than propagating, the same
/// contract `deliver::deliver` follows: there is no caller left to report to,
/// only the process log, and the live WebSocket ring already reached a
/// connected client regardless of whether this push ever lands.
pub(super) async fn deliver(
    enabled: Arc<Enabled>,
    store: Store,
    channel_id: ChannelId,
    ring_id: CallRingId,
    caller_id: UserId,
    callee_id: UserId,
) {
    let preference = match store
        .channel_notification_preferences(channel_id, None, &[callee_id])
        .await
    {
        Ok(preferences) => preferences.get(&callee_id).copied().unwrap_or_default(),
        Err(err) => {
            tracing::warn!(error = %err, %channel_id, "push: failed to resolve a call ring's notification preference");
            return;
        }
    };
    // Only an outright opt-out suppresses a ring; see this module's own doc.
    if preference == NotificationPreference::Nothing {
        return;
    }

    let targets = match store.push_targets(&[callee_id]).await {
        Ok(targets) => targets,
        Err(err) => {
            tracing::warn!(error = %err, %channel_id, "push: failed to load a call ring's push targets");
            return;
        }
    };
    let now = now_ms();
    let targets: Vec<_> = targets
        .into_iter()
        .filter(|target| !is_foreground_and_recent(target, now))
        .collect();
    if targets.is_empty() {
        return;
    }

    let caller_name = match store.user_profile(caller_id).await {
        Ok(Some(profile)) => Some(profile.display_name),
        Ok(None) => None,
        Err(err) => {
            tracing::warn!(error = %err, "push: failed to resolve a call ring's caller name");
            None
        }
    };

    let sent_at = now_ms();
    let messages = seal_for_call_ring(
        channel_id,
        ring_id,
        caller_id,
        caller_name.as_deref(),
        sent_at,
        &targets,
    );
    if messages.is_empty() {
        return;
    }

    dispatch::send_and_prune(&enabled, &store, &messages, "call ring").await;
}

/// The sealed plaintext for a DM call ring.
#[derive(Serialize)]
struct CallRingEnvelope<'a> {
    domain: &'static str,
    version: u8,
    kind: PushKind,
    channel_id: String,
    ring_id: String,
    caller_id: String,
    sent_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    caller_name: Option<&'a str>,
}

/// Seals a DM call ring notification to every target's public key, the same
/// per-device sealing [`envelope::seal_for_message`] does for a message.
fn seal_for_call_ring(
    channel_id: ChannelId,
    ring_id: CallRingId,
    caller_id: UserId,
    caller_name: Option<&str>,
    sent_at: i64,
    targets: &[crate::store::PushTarget],
) -> Vec<SealedMessage> {
    let Some(bare) = encode(channel_id, ring_id, caller_id, sent_at, None) else {
        return Vec::new();
    };
    let with_content = caller_name
        .and_then(|name| encode(channel_id, ring_id, caller_id, sent_at, Some(name)))
        .filter(|plaintext| plaintext.len() <= MAX_ENVELOPE_PLAINTEXT_BYTES);

    targets
        .iter()
        .filter_map(|target| {
            let plaintext = match (target.include_content, &with_content) {
                (true, Some(with_content)) => with_content,
                _ => &bare,
            };
            seal_to(target, ring_slot(target), PushKind::Call, plaintext).map(|message| {
                SealedMessage {
                    ring_id: Some(ring_id),
                    ..message
                }
            })
        })
        .collect()
}

/// iOS rings through PushKit, whose topic only accepts the VoIP token; a device that never
/// registered one is skipped rather than sent a ring APNs would refuse.
fn ring_slot(target: &crate::store::PushTarget) -> TokenSlot {
    if target.platform == "ios" {
        TokenSlot::Voip
    } else {
        TokenSlot::Push
    }
}

fn encode(
    channel_id: ChannelId,
    ring_id: CallRingId,
    caller_id: UserId,
    sent_at: i64,
    caller_name: Option<&str>,
) -> Option<Vec<u8>> {
    let truncated_name = caller_name.map(|name| truncate(name, MAX_PREVIEW_NAME_CHARS, false));
    let envelope = CallRingEnvelope {
        domain: DOMAIN,
        version: ENVELOPE_VERSION,
        kind: PushKind::Call,
        channel_id: channel_id.to_string(),
        ring_id: ring_id.to_string(),
        caller_id: caller_id.to_string(),
        sent_at,
        caller_name: truncated_name.as_deref(),
    };
    match serde_json::to_vec(&envelope) {
        Ok(bytes) => Some(bytes),
        Err(err) => {
            tracing::error!(error = %err, "push: call ring envelope failed to serialize");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `channel_id`, `ring_id` and `caller_id` are never content: every
    /// device gets them regardless of `include_content`, since a receiving
    /// device could already resolve who is calling from `channel_id` alone.
    #[test]
    fn ids_ride_unconditionally_but_the_name_does_not() {
        let bare = encode(
            ChannelId::generate(),
            CallRingId::generate(),
            UserId::generate(),
            1_700_000_000_000,
            None,
        )
        .expect("encodes");
        let value: serde_json::Value = serde_json::from_slice(&bare).expect("valid json");
        assert_eq!(value["kind"], "call");
        assert!(value.get("caller_name").is_none());

        let with_name = encode(
            ChannelId::generate(),
            CallRingId::generate(),
            UserId::generate(),
            1_700_000_000_000,
            Some("Ada"),
        )
        .expect("encodes");
        let value: serde_json::Value = serde_json::from_slice(&with_name).expect("valid json");
        assert_eq!(value["caller_name"], "Ada");
    }

    /// Nothing here is variable-length except three uuids, a `caller_id` and
    /// a `sent_at`, so the content-free envelope always has to fit - the same
    /// property `envelope::tests::the_content_free_envelope_always_fits_the_budget`
    /// pins for a message.
    #[test]
    fn the_content_free_envelope_always_fits_the_budget() {
        let bare = encode(
            ChannelId::generate(),
            CallRingId::generate(),
            UserId::generate(),
            i64::MAX,
            None,
        )
        .expect("the content-free ring envelope always encodes");
        assert!(bare.len() <= MAX_ENVELOPE_PLAINTEXT_BYTES);
    }
}
