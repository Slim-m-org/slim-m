// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Host-run connectors (decision 0134): the server asks the separate supervisor to create,
//! start, stop and remove a connector's container. Built only when the operator sets
//! `SLIMM_CONNECTOR_SUPERVISOR_SOCKET` and `SLIMM_SUPERVISOR_SECRET`; unset, nothing here runs.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};

use serde_json::Value;
use tokio::sync::Notify;

pub mod client;
pub(crate) mod crashes;
pub(crate) mod lifecycle;
mod monitor;

pub use client::{SupervisorClient, SupervisorError};
pub use monitor::{spawn_monitor, tick};

/// The supervisor's last known answer.
#[derive(Debug, Clone, PartialEq)]
pub enum Health {
    /// Not asked yet.
    Unknown,
    /// `hello` answered; the body says whether the runtime can enforce the sandbox.
    Up(Value),
    /// The supervisor or its runtime could not be reached.
    Down(String),
}

/// The client, what the server last heard from it, and each connector's crash log.
pub struct HostRunner {
    pub(crate) client: SupervisorClient,
    /// The address a connector reaches the server's API at, handed over as `SLIMM_API_URL`.
    pub(crate) api_url: String,
    health: RwLock<Health>,
    pub(crate) crashes: Mutex<HashMap<String, crashes::CrashLog>>,
    pub(crate) retries: Mutex<HashMap<String, crashes::Retry>>,
    pub(crate) wake: Notify,
}

pub type HostRun = Arc<HostRunner>;

impl HostRunner {
    pub fn new(client: SupervisorClient, api_url: String) -> HostRun {
        Arc::new(Self {
            client,
            api_url,
            health: RwLock::new(Health::Unknown),
            crashes: Mutex::default(),
            retries: Mutex::default(),
            wake: Notify::new(),
        })
    }

    /// `None` unless both the socket and a secret are configured.
    pub fn from_config(config: &crate::config::Config) -> Option<HostRun> {
        let socket = config.connector_supervisor_socket.as_deref()?;
        let Some(secret) = config.supervisor_secret.clone() else {
            tracing::warn!(
                "SLIMM_CONNECTOR_SUPERVISOR_SOCKET is set without SLIMM_SUPERVISOR_SECRET; host-run connectors stay off"
            );
            return None;
        };
        let api_url = config
            .connector_api_url
            .clone()
            .unwrap_or_else(|| "http://server:8080".to_owned());
        Some(Self::new(SupervisorClient::new(socket, secret), api_url))
    }

    pub fn health(&self) -> Health {
        self.health
            .read()
            .map(|h| h.clone())
            .unwrap_or(Health::Unknown)
    }

    pub(crate) fn set_health(&self, health: Health) {
        if let Ok(mut current) = self.health.write() {
            *current = health;
        }
    }

    /// Why the runtime cannot take a request right now, or `None` when it can.
    pub fn unavailable_reason(&self) -> Option<String> {
        match self.health() {
            Health::Up(hello) if hello.get("ready").and_then(Value::as_bool) != Some(false) => None,
            Health::Up(hello) => Some(problems(&hello)),
            Health::Down(reason) => Some(reason),
            Health::Unknown => Some("the connector supervisor has not answered yet".to_owned()),
        }
    }

    /// Asks the monitor to reconcile now instead of at its next tick.
    pub fn nudge(&self) {
        self.wake.notify_one();
    }

    pub(crate) fn restarts(&self, module_id: &str) -> usize {
        self.crashes
            .lock()
            .map(|c| c.get(module_id).map_or(0, crashes::CrashLog::restarts))
            .unwrap_or(0)
    }

    pub(crate) fn forget_crashes(&self, module_id: &str) {
        if let Ok(mut crashes) = self.crashes.lock() {
            crashes.remove(module_id);
        }
        if let Ok(mut retries) = self.retries.lock() {
            retries.remove(module_id);
        }
    }

    /// Whether a failed create or start for this connector may be tried again now.
    pub(crate) fn retry_due(&self, module_id: &str, now: i64) -> bool {
        self.retries
            .lock()
            .map(|r| r.get(module_id).is_none_or(|r| r.due(now)))
            .unwrap_or(true)
    }

    pub(crate) fn note_attempt(&self, module_id: &str, ok: bool, now: i64) {
        if let Ok(mut retries) = self.retries.lock() {
            if ok {
                retries.remove(module_id);
            } else {
                retries.entry(module_id.to_owned()).or_default().failed(now);
            }
        }
    }
}

fn problems(hello: &Value) -> String {
    let listed: Vec<&str> = hello
        .get("problems")
        .and_then(Value::as_array)
        .map(|p| p.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    format!(
        "the container runtime cannot enforce the sandbox: {}",
        listed.join("; ")
    )
}
