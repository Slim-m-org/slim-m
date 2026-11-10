// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pushing an account security alert, today a sign-in from a device the account has not
//! used before, to the account's other devices.
//!
//! Not gated by notification preferences or the schedule: it is about the account's safety,
//! not a conversation, and `Class::SignInAlert` already bounds how often it can fire.

use std::sync::Arc;

use serde::Serialize;

use crate::ids::{DeviceId, UserId};
use crate::store::{Store, now_ms};

use super::deliver::is_foreground_and_recent;
use super::envelope::{DOMAIN, ENVELOPE_VERSION, MAX_PREVIEW_NAME_CHARS, PushKind, truncate};
use super::sealing::{TokenSlot, seal_to};
use super::{Enabled, dispatch};

/// What happened, sealed so the relay learns only the coarse `security` kind.
#[derive(Serialize)]
struct SecurityEnvelope<'a> {
    domain: &'static str,
    version: u8,
    kind: PushKind,
    event: &'static str,
    sent_at: i64,
    signed_in_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    device_name: Option<&'a str>,
}

/// A sign-in the account has not seen before, as the push path needs it.
pub struct NewDeviceSignIn {
    pub user_id: UserId,
    pub device_id: DeviceId,
    pub device_name: String,
    pub signed_in_at: i64,
}

pub(super) async fn deliver(enabled: Arc<Enabled>, store: Store, sign_in: NewDeviceSignIn) {
    let targets = match store.push_targets(&[sign_in.user_id]).await {
        Ok(targets) => targets,
        Err(err) => {
            tracing::warn!(error = %err, "push: failed to load a sign-in alert's push targets");
            return;
        }
    };
    let now = now_ms();
    let device_name = truncate(&sign_in.device_name, MAX_PREVIEW_NAME_CHARS, false);
    let encode = |device_name: Option<&str>| {
        serde_json::to_vec(&SecurityEnvelope {
            domain: DOMAIN,
            version: ENVELOPE_VERSION,
            kind: PushKind::Security,
            event: "new_device_sign_in",
            sent_at: now,
            signed_in_at: sign_in.signed_in_at,
            device_name,
        })
    };
    let (Ok(bare), Ok(named)) = (encode(None), encode(Some(&device_name))) else {
        tracing::error!("push: sign-in alert envelope failed to serialize");
        return;
    };
    // The new device is the one signing in, and a foreground device already has the live alert.
    let messages: Vec<_> = targets
        .iter()
        .filter(|target| target.device_id != sign_in.device_id)
        .filter(|target| !is_foreground_and_recent(target, now))
        .filter_map(|target| {
            let plaintext = if target.include_content {
                &named
            } else {
                &bare
            };
            seal_to(target, TokenSlot::Push, PushKind::Security, plaintext)
        })
        .collect();
    dispatch::send_and_prune(&enabled, &store, &messages, "sign-in alert").await;
}
