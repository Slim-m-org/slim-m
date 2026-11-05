// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pushing an operator alert to the unmuted holders of `MANAGE_SERVER`.
//!
//! Rides the relay's coarse `security` kind with its own sealed event, so a relay that predates
//! alerts still delivers it. The sealed words are the server's own, never member content.

use std::sync::Arc;

use serde::Serialize;

use crate::ids::UserId;
use crate::store::{Store, now_ms};

use super::deliver::is_foreground_and_recent;
use super::envelope::{DOMAIN, ENVELOPE_VERSION, PushKind, truncate};
use super::sealing::{TokenSlot, seal_to};
use super::{Enabled, dispatch};

const MAX_TITLE_CHARS: usize = 60;
const MAX_BODY_CHARS: usize = 160;

/// The words of one alert, as the push path needs them.
pub struct AdminAlertPush {
    pub title: String,
    pub body: String,
}

#[derive(Serialize)]
struct AdminAlertEnvelope<'a> {
    domain: &'static str,
    version: u8,
    kind: PushKind,
    event: &'static str,
    sent_at: i64,
    title: &'a str,
    body: &'a str,
}

pub(super) async fn deliver(
    enabled: Arc<Enabled>,
    store: Store,
    recipients: Vec<UserId>,
    alert: AdminAlertPush,
) {
    let targets = match store.push_targets(&recipients).await {
        Ok(targets) => targets,
        Err(err) => {
            tracing::warn!(error = %err, "push: failed to load an admin alert's push targets");
            return;
        }
    };
    let now = now_ms();
    let title = truncate(&alert.title, MAX_TITLE_CHARS, true);
    let body = truncate(&alert.body, MAX_BODY_CHARS, true);
    let Ok(plaintext) = serde_json::to_vec(&AdminAlertEnvelope {
        domain: DOMAIN,
        version: ENVELOPE_VERSION,
        kind: PushKind::Security,
        event: "admin_alert",
        sent_at: now,
        title: &title,
        body: &body,
    }) else {
        tracing::error!("push: admin alert envelope failed to serialize");
        return;
    };
    // A foreground device already shows the live notice.
    let messages: Vec<_> = targets
        .iter()
        .filter(|target| !is_foreground_and_recent(target, now))
        .filter_map(|target| seal_to(target, TokenSlot::Push, PushKind::Security, &plaintext))
        .collect();
    dispatch::send_and_prune(&enabled, &store, &messages, "admin alert").await;
}
