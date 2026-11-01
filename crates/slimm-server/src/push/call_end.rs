// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Telling a callee's Android devices that a ring ended, so a phone still showing it stops.
//!
//! Android only: iOS terminates an app that takes a VoIP push without reporting a new call,
//! so an iOS ring has to learn it ended from the app itself once CallKit wakes it.

use std::sync::Arc;

use serde::Serialize;

use crate::ids::{CallRingId, ChannelId, UserId};
use crate::notifications::NotificationPreference;
use crate::store::{Store, now_ms};

use super::envelope::{DOMAIN, ENVELOPE_VERSION, PushKind};
use super::sealing::{TokenSlot, seal_to};
use super::{Enabled, dispatch};

#[derive(Serialize)]
struct CallEndEnvelope {
    domain: &'static str,
    version: u8,
    kind: PushKind,
    channel_id: String,
    ring_id: String,
    sent_at: i64,
}

/// Sends a `call_end` for `ring_id` to every other participant of `caller_id`'s DM.
pub(super) async fn deliver(
    enabled: Arc<Enabled>,
    store: Store,
    channel_id: ChannelId,
    ring_id: CallRingId,
    caller_id: UserId,
) {
    let callees: Vec<UserId> = match store.dm_participants(channel_id).await {
        Ok(Some(participants)) => participants
            .into_iter()
            .filter(|participant| *participant != caller_id)
            .collect(),
        Ok(None) => return,
        Err(err) => {
            tracing::warn!(error = %err, %channel_id, "push: failed to resolve a ring's callees");
            return;
        }
    };
    let preferences = match store
        .channel_notification_preferences(channel_id, None, &callees)
        .await
    {
        Ok(preferences) => preferences,
        Err(err) => {
            tracing::warn!(error = %err, %channel_id, "push: failed to resolve a ring end's preference");
            return;
        }
    };
    // The ring itself was never pushed to an account that opted out of everything.
    let callees: Vec<UserId> = callees
        .into_iter()
        .filter(|callee| {
            preferences.get(callee).copied().unwrap_or_default() != NotificationPreference::Nothing
        })
        .collect();
    if callees.is_empty() {
        return;
    }
    let targets = match store.push_targets(&callees).await {
        Ok(targets) => targets,
        Err(err) => {
            tracing::warn!(error = %err, %channel_id, "push: failed to load a ring end's push targets");
            return;
        }
    };
    let envelope = CallEndEnvelope {
        domain: DOMAIN,
        version: ENVELOPE_VERSION,
        kind: PushKind::CallEnd,
        channel_id: channel_id.to_string(),
        ring_id: ring_id.to_string(),
        sent_at: now_ms(),
    };
    let Ok(plaintext) = serde_json::to_vec(&envelope) else {
        tracing::error!("push: call end envelope failed to serialize");
        return;
    };
    // Foreground devices too: one opened mid-ring may still show the ring's notification.
    let messages: Vec<_> = targets
        .iter()
        .filter(|target| target.platform == "android")
        .filter_map(|target| seal_to(target, TokenSlot::Push, PushKind::CallEnd, &plaintext))
        .collect();
    dispatch::send_and_prune(&enabled, &store, &messages, "call end").await;
}
