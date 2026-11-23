// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The four verbs and three reads, on containers this instance labelled and nothing else.

use std::sync::Arc;

use serde::Serialize;
use serde_json::{Value, json};
use tokio::sync::{Mutex, RwLock};

use crate::checks::{self, Readiness};
use crate::config::Config;
use crate::error::{ApiError, Code};
use crate::logs::{self, Line};
use crate::net::HostPort;
use crate::policy::{self, CreateRequest, Spec};
use crate::runtime::{Runtime, encode, label_filter};
use crate::sandbox::{
    self, EGRESS, EGRESS_PRIVATE, INSTANCE, MANAGED_BY, MANAGED_BY_VALUE, Names, ROLE, SPEC, VOLUME,
};

mod gateway_plan;
mod objects;
pub mod volumes;

/// The host's own LAN address is a private address like any other, so the Private network
/// is safe to grant only once the operator has named it.
pub const PRIVATE_NEEDS_DENY: &str = "the Private network needs the operator to list the docker host's own LAN addresses in SLIMM_SUPERVISOR_LAN_DENY first";

pub struct Supervisor {
    pub config: Config,
    pub instance: String,
    pub runtime: Runtime,
    readiness: RwLock<Option<Readiness>>,
    verbs: Mutex<()>,
    volumes: RwLock<std::collections::HashMap<String, volumes::Usage>>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ConnectorState {
    pub id: String,
    pub state: &'static str,
    pub exit_code: Option<i64>,
    pub oom_killed: bool,
    pub started_at: Option<String>,
    pub finished_at: Option<String>,
    pub image: Option<String>,
    /// The data volume's size at the last measurement, when it has one.
    pub volume_bytes: Option<u64>,
    /// The supervisor stopped it, or refuses to start it, because its volume is over the ceiling.
    pub volume_over_limit: bool,
}

impl Supervisor {
    pub fn new(config: Config, instance: String) -> Arc<Self> {
        let runtime = Runtime::new(&config.runtime_socket);
        Arc::new(Self {
            config,
            instance,
            runtime,
            readiness: RwLock::new(None),
            verbs: Mutex::new(()),
            volumes: RwLock::new(Default::default()),
        })
    }

    fn names(&self, id: &str) -> Names {
        Names::new(&self.instance, id)
    }

    /// Runs the startup checks again and remembers the answer.
    pub async fn refresh_readiness(&self) -> Result<Readiness, ApiError> {
        let result = checks::check(
            &self.runtime,
            &self.instance,
            &self.config.egress_network,
            &self.config.own_image,
            self.config.requirements,
        )
        .await;
        *self.readiness.write().await = result.as_ref().ok().cloned();
        result
    }

    async fn require_ready(&self) -> Result<(), ApiError> {
        let cached = self.readiness.read().await.clone();
        let readiness = match cached {
            Some(r) if r.ready() => return Ok(()),
            _ => self.refresh_readiness().await?,
        };
        if readiness.ready() {
            return Ok(());
        }
        Err(ApiError::runtime(format!(
            "the runtime cannot enforce the sandbox: {}",
            readiness.problems.join("; ")
        )))
    }

    /// Probes the runtime only until it is ready; afterwards a down runtime shows as `list` failing.
    pub async fn hello(&self) -> Result<Value, ApiError> {
        let cached = self.readiness.read().await.clone();
        let readiness = match cached {
            Some(r) if r.ready() => r,
            _ => self.refresh_readiness().await?,
        };
        let connectors = self.list().await?.len();
        Ok(json!({
            "v": 1,
            "protocol": "supervisor/1",
            "version": env!("CARGO_PKG_VERSION"),
            "runtime": readiness.runtime,
            "rootless": readiness.rootless,
            "ready": readiness.ready(),
            "problems": readiness.problems,
            "ceilings": self.config.ceilings,
            "registries": self.config.registries,
            "private_network": !self.config.lan_deny.is_empty(),
            "connectors": connectors,
        }))
    }

    pub async fn create(&self, id: &str, req: CreateRequest) -> Result<(), ApiError> {
        let spec = policy::validate(req, &self.config.registries, &self.config.ceilings)?;
        if spec.egress_private && self.config.lan_deny.is_empty() {
            return Err(ApiError::policy(PRIVATE_NEEDS_DENY));
        }
        let _guard = self.verbs.lock().await;
        self.require_ready().await?;
        let names = self.names(id);
        if let Some(existing) = self
            .owned_container(&names.container, &names, "connector")
            .await?
        {
            return match label(&existing, SPEC) == Some(spec.fingerprint().as_str()) {
                true => Ok(()),
                false => Err(ApiError::new(
                    Code::Conflict,
                    "a different connector with this id exists; remove it first",
                )),
            };
        }
        if self.list().await?.len() >= self.config.ceilings.max_connectors {
            return Err(ApiError::limit(format!(
                "the supervisor runs at most {} connectors",
                self.config.ceilings.max_connectors
            )));
        }
        let result = self.build(&names, &spec).await;
        if result.is_err() {
            let _ = self.teardown(&names, true).await;
        }
        result
    }

    async fn build(&self, names: &Names, spec: &Spec) -> Result<(), ApiError> {
        self.ensure_image(&spec.image).await?;
        self.ensure_network(names).await?;
        if spec.volume {
            self.ensure_volume(names).await?;
        }
        self.create_container(&names.container, &sandbox::connector_container(names, spec))
            .await?;
        self.recreate_gateway(names).await
    }

    async fn ensure_image(&self, image: &str) -> Result<(), ApiError> {
        if self
            .runtime
            .get(&format!("/images/{image}/json"))
            .await?
            .status
            .is_success()
        {
            return Ok(());
        }
        self.runtime.pull(image).await
    }

    pub async fn start(&self, id: &str) -> Result<(), ApiError> {
        let _guard = self.verbs.lock().await;
        self.require_ready().await?;
        let names = self.names(id);
        let Some(existing) = self
            .owned_container(&names.container, &names, "connector")
            .await?
        else {
            return Err(ApiError::new(Code::NotFound, "no such connector"));
        };
        if let Some(usage) = self.measure(id, &existing).await?
            && usage.over()
        {
            return Err(ApiError::limit(format!(
                "the connector's data volume holds {} MiB, over its {} MiB limit",
                usage.bytes.div_ceil(1024 * 1024),
                usage.limit_mib
            )));
        }
        self.recreate_gateway(&names).await?;
        self.start_container(&names.gateway).await?;
        self.start_container(&names.container).await
    }

    pub async fn stop(&self, id: &str, timeout_s: u64) -> Result<(), ApiError> {
        let _guard = self.verbs.lock().await;
        let names = self.names(id);
        if self
            .owned_container(&names.container, &names, "connector")
            .await?
            .is_none()
        {
            return Err(ApiError::new(Code::NotFound, "no such connector"));
        }
        self.stop_container(&names.container, timeout_s).await?;
        if self
            .owned_container(&names.gateway, &names, "gateway")
            .await?
            .is_some()
        {
            self.stop_container(&names.gateway, 2).await?;
        }
        Ok(())
    }

    pub async fn remove(&self, id: &str, keep_volume: bool) -> Result<(), ApiError> {
        let _guard = self.verbs.lock().await;
        self.remember_usage(id, None).await;
        self.teardown(&self.names(id), keep_volume).await
    }

    pub async fn list(&self) -> Result<Vec<ConnectorState>, ApiError> {
        let filter = label_filter(&[(MANAGED_BY, MANAGED_BY_VALUE), (INSTANCE, &self.instance)]);
        let reply = self
            .runtime
            .get(&format!("/containers/json?all=true&filters={filter}"))
            .await?;
        if !reply.status.is_success() {
            return Err(ApiError::runtime(reply.message()));
        }
        let mut found: std::collections::BTreeMap<String, ConnectorState> = Default::default();
        for item in reply.json().as_array().cloned().unwrap_or_default() {
            let labels = item.get("Labels").cloned().unwrap_or(Value::Null);
            let Some(id) = labels
                .get(sandbox::CONNECTOR)
                .and_then(Value::as_str)
                .map(str::to_owned)
            else {
                continue;
            };
            let role = labels.get(ROLE).and_then(Value::as_str).unwrap_or_default();
            if role == "connector" {
                let name = item
                    .pointer("/Id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let inspected = self
                    .runtime
                    .get(&format!("/containers/{name}/json"))
                    .await?
                    .json();
                let mut state = state_of(&id, &inspected);
                if let Some(usage) = self.usage(&id).await {
                    state.volume_bytes = Some(usage.bytes);
                    state.volume_over_limit = usage.over();
                }
                found.insert(id.clone(), state);
            } else if role == "gateway" {
                found.entry(id.clone()).or_insert_with(|| missing(&id));
            }
        }
        Ok(found.into_values().collect())
    }

    pub async fn logs(&self, id: &str, tail: usize, since: u64) -> Result<Vec<Line>, ApiError> {
        let names = self.names(id);
        if self
            .owned_container(&names.container, &names, "connector")
            .await?
            .is_none()
        {
            return Err(ApiError::new(Code::NotFound, "no such connector"));
        }
        let tail = tail.clamp(1, logs::MAX_LINES);
        let path = format!(
            "/containers/{}/logs?stdout=1&stderr=1&timestamps=1&tail={tail}&since={since}",
            encode(&names.container)
        );
        let reply = self.runtime.get(&path).await?;
        if !reply.status.is_success() {
            return Err(ApiError::runtime(reply.message()));
        }
        Ok(logs::demux(&reply.body))
    }

    fn server(&self) -> &HostPort {
        &self.config.server
    }
}

fn label<'a>(inspected: &'a Value, key: &str) -> Option<&'a str> {
    inspected.get("Config")?.get("Labels")?.get(key)?.as_str()
}

fn missing(id: &str) -> ConnectorState {
    ConnectorState {
        id: id.to_owned(),
        state: "missing",
        exit_code: None,
        oom_killed: false,
        started_at: None,
        finished_at: None,
        image: None,
        volume_bytes: None,
        volume_over_limit: false,
    }
}

/// Maps the runtime's container state onto `created`, `running` or `exited`.
pub fn state_of(id: &str, inspected: &Value) -> ConnectorState {
    let state = inspected.get("State").cloned().unwrap_or(Value::Null);
    let status = state
        .get("Status")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let mapped = match status {
        "running" | "restarting" | "paused" => "running",
        "created" => "created",
        _ => "exited",
    };
    let time = |key: &str| {
        state
            .get(key)
            .and_then(Value::as_str)
            .filter(|t| !t.starts_with("0001-"))
            .map(str::to_owned)
    };
    ConnectorState {
        id: id.to_owned(),
        state: mapped,
        exit_code: (mapped == "exited")
            .then(|| state.get("ExitCode").and_then(Value::as_i64))
            .flatten(),
        oom_killed: state
            .get("OOMKilled")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        started_at: time("StartedAt"),
        finished_at: time("FinishedAt"),
        image: inspected
            .pointer("/Config/Image")
            .and_then(Value::as_str)
            .map(str::to_owned),
        volume_bytes: None,
        volume_over_limit: false,
    }
}

/// The labels a connector container carries that the gateway is rebuilt from.
fn egress_of(inspected: &Value) -> (Vec<HostPort>, bool, bool) {
    let egress = label(inspected, EGRESS)
        .and_then(|raw| serde_json::from_str(raw).ok())
        .unwrap_or_default();
    let private = label(inspected, EGRESS_PRIVATE) == Some("1");
    let volume = label(inspected, VOLUME) == Some("1");
    (egress, private, volume)
}

#[cfg(test)]
mod tests;
