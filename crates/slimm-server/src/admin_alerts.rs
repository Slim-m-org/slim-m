// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Operator alerts for holders of `MANAGE_SERVER`: LiveKit down, a full disk, a failing sweep,
//! a stale backup, a tripped module breaker and a push relay that stopped answering.
//!
//! Each condition is one row (kind plus subject) that opens, stays one row while it lasts, and
//! recovers. Opening tells the in-app clients over the hub and pushes at most once per kind per
//! [`PUSH_WINDOW_MS`]; recovering pushes a notice only when the opening was pushed. Policy
//! lives in docs/decisions/0108-admin-alerts.md.

pub mod backup_status;
mod monitor;
pub mod watch;

pub use monitor::{Monitor, MonitorSettings, spawn_monitor};

use crate::hub::{Event, Hub};
use crate::push::{AdminAlertPush, PushSender};
use crate::store::{Raised, Store, now_ms};

/// One push per kind in this window, however often the condition flaps.
pub const PUSH_WINDOW_MS: i64 = 6 * 60 * 60 * 1000;

/// How long a recovered alert stays in the list.
pub const RECOVERED_VISIBLE_MS: i64 = 24 * 60 * 60 * 1000;

/// The conditions an operator hears about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AlertKind {
    Livekit,
    DiskLow,
    SweepFailing,
    Backup,
    ModuleBreaker,
    PushRelay,
}

impl AlertKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Livekit => "livekit_unreachable",
            Self::DiskLow => "disk_low",
            Self::SweepFailing => "sweep_failing",
            Self::Backup => "backup",
            Self::ModuleBreaker => "module_breaker",
            Self::PushRelay => "push_relay",
        }
    }

    const fn title(self) -> &'static str {
        match self {
            Self::Livekit => "Voice server unreachable",
            Self::DiskLow => "Disk space is low",
            Self::SweepFailing => "A background job is failing",
            Self::Backup => "Backup needs attention",
            Self::ModuleBreaker => "A module was turned off",
            Self::PushRelay => "Push relay is failing",
        }
    }
}

/// The handles an alert needs, so the module breaker and the monitor share one path.
#[derive(Clone)]
pub struct Notifier {
    store: Store,
    hub: Hub,
    push: PushSender,
}

impl Notifier {
    pub fn new(store: Store, hub: Hub, push: PushSender) -> Self {
        Self { store, hub, push }
    }

    pub fn from_state(state: &crate::state::AppState) -> Self {
        Self::new(state.store.clone(), state.hub.clone(), state.push.clone())
    }

    /// Opens the condition. A condition that is already open changes nothing visible.
    pub async fn raise(&self, kind: AlertKind, subject: &str, detail: &str) {
        let now = now_ms();
        match self
            .store
            .raise_admin_alert(kind.as_str(), subject, detail, now)
            .await
        {
            Ok(Raised::AlreadyOpen) => {}
            Ok(Raised::Opened) => {
                self.hub.publish(Event::AdminAlertsChanged);
                self.push_if_allowed(kind, subject, kind.title(), detail, now)
                    .await;
            }
            Err(err) => {
                tracing::warn!(error = %err, kind = kind.as_str(), "could not raise an admin alert")
            }
        }
    }

    /// Closes the condition and, when its opening was pushed, says it recovered.
    pub async fn resolve(&self, kind: AlertKind, subject: &str) {
        let now = now_ms();
        match self
            .store
            .resolve_admin_alert(kind.as_str(), subject, now)
            .await
        {
            Ok(None) => {}
            Ok(Some(resolved)) => {
                self.hub.publish(Event::AdminAlertsChanged);
                if resolved.notified {
                    let title = format!("Recovered: {}", kind.title());
                    self.push_to_recipients(&title, &resolved.alert.detail)
                        .await;
                }
            }
            Err(err) => {
                tracing::warn!(error = %err, kind = kind.as_str(), "could not resolve an admin alert")
            }
        }
    }

    async fn push_if_allowed(
        &self,
        kind: AlertKind,
        subject: &str,
        title: &str,
        body: &str,
        now: i64,
    ) {
        match self
            .store
            .claim_admin_alert_push(kind.as_str(), subject, now, PUSH_WINDOW_MS)
            .await
        {
            Ok(true) => self.push_to_recipients(title, body).await,
            Ok(false) => {}
            Err(err) => tracing::warn!(error = %err, "could not claim an admin alert push"),
        }
    }

    async fn push_to_recipients(&self, title: &str, body: &str) {
        if !self.push.is_enabled() {
            return;
        }
        match self.store.admin_alert_recipients().await {
            Ok(recipients) if !recipients.is_empty() => self.push.notify_admin_alert(
                self.store.clone(),
                recipients,
                AdminAlertPush {
                    title: title.to_owned(),
                    body: body.to_owned(),
                },
            ),
            Ok(_) => {}
            Err(err) => tracing::warn!(error = %err, "could not list admin alert recipients"),
        }
    }
}
