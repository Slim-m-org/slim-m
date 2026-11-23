// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The data volume ceiling: a named local volume has no size limit of its own, so the
//! supervisor measures each connector's volume on a timer and stops the connector when it is
//! over (decision 0134, amendment of 2026-11-23).

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use serde_json::Value;

use super::{Supervisor, label};
use crate::error::ApiError;
use crate::policy::DEFAULT_VOLUME_MIB;
use crate::runtime::label_filter;
use crate::sandbox::{CONNECTOR, INSTANCE, MANAGED_BY, MANAGED_BY_VALUE, ROLE, VOLUME, VOLUME_MIB};

/// How often volumes are measured; a connector can write past its ceiling for this long.
pub const CHECK_EVERY: Duration = Duration::from_secs(30);
const MIB: u64 = 1024 * 1024;
/// How long the runtime may take to report every volume on the host before the check fails.
const SIZES_WITHIN: Duration = Duration::from_secs(20);
/// Checks in a row that could not read the sizes before connectors with a volume are stopped.
pub const BLIND_CHECKS_BEFORE_STOPPING: u32 = 3;

/// One connector volume's last measured size against its ceiling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Usage {
    pub bytes: u64,
    pub limit_mib: u64,
}

impl Usage {
    pub fn over(&self) -> bool {
        self.bytes > self.limit_mib * MIB
    }
}

/// This instance's connector volume sizes by connector id, from the runtime's disk usage report.
pub fn sizes_of(df: &Value, instance: &str) -> HashMap<String, u64> {
    let mut sizes = HashMap::new();
    for volume in df
        .get("Volumes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let labels = volume.get("Labels").cloned().unwrap_or(Value::Null);
        let get = |key: &str| labels.get(key).and_then(Value::as_str);
        let ours = get(MANAGED_BY) == Some(MANAGED_BY_VALUE)
            && get(INSTANCE) == Some(instance)
            && get(ROLE) == Some("volume");
        let size = volume.pointer("/UsageData/Size").and_then(Value::as_i64);
        if let (true, Some(id), Some(size)) = (ours, get(CONNECTOR), size)
            && size >= 0
        {
            sizes.insert(id.to_owned(), size as u64);
        }
    }
    sizes
}

/// The ceiling a connector container carries; an unlabelled one gets the default.
pub fn limit_of(inspected: &Value) -> Option<u64> {
    if label(inspected, VOLUME) != Some("1") {
        return None;
    }
    Some(
        label(inspected, VOLUME_MIB)
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_VOLUME_MIB),
    )
}

impl Supervisor {
    async fn volume_sizes(&self) -> Result<HashMap<String, u64>, ApiError> {
        let reply = self
            .runtime
            .get_within("/system/df?type=volume", SIZES_WITHIN)
            .await?;
        if !reply.status.is_success() {
            return Err(ApiError::runtime(reply.message()));
        }
        Ok(sizes_of(&reply.json(), &self.instance))
    }

    /// The usage of one connector's volume measured now, or `None` when it has none.
    pub(super) async fn measure(
        &self,
        id: &str,
        inspected: &Value,
    ) -> Result<Option<Usage>, ApiError> {
        let Some(limit_mib) = limit_of(inspected) else {
            return Ok(None);
        };
        let bytes = self.volume_sizes().await?.get(id).copied().unwrap_or(0);
        let usage = Usage { bytes, limit_mib };
        self.remember_usage(id, Some(usage)).await;
        Ok(Some(usage))
    }

    pub(super) async fn remember_usage(&self, id: &str, usage: Option<Usage>) {
        let mut known = self.volumes.write().await;
        match usage {
            Some(usage) => known.insert(id.to_owned(), usage),
            None => known.remove(id),
        };
    }

    pub(super) async fn usage(&self, id: &str) -> Option<Usage> {
        self.volumes.read().await.get(id).copied()
    }

    /// Measures every connector volume and stops each running connector that is over its ceiling.
    /// The runtime cannot report one volume alone, so every volume on the host is read; when that
    /// keeps failing the ceiling cannot be enforced, so connectors with a volume are stopped.
    pub async fn check_volumes(&self) -> Result<(), ApiError> {
        let sizes = match self.volume_sizes().await {
            Ok(sizes) => {
                self.blind_checks.store(0, Ordering::Relaxed);
                sizes
            }
            Err(err) => {
                let blind = self.blind_checks.fetch_add(1, Ordering::Relaxed) + 1;
                if blind >= BLIND_CHECKS_BEFORE_STOPPING {
                    self.stop_unmeasurable(blind, &err.detail).await?;
                }
                return Err(err);
            }
        };
        for item in self.connector_containers().await? {
            let Some(id) = item
                .pointer("/Labels")
                .and_then(|l| l.get(CONNECTOR))
                .and_then(Value::as_str)
            else {
                continue;
            };
            let as_inspected = serde_json::json!({"Config": {"Labels": item.get("Labels")}});
            let Some(limit_mib) = limit_of(&as_inspected) else {
                continue;
            };
            let usage = Usage {
                bytes: sizes.get(id).copied().unwrap_or(0),
                limit_mib,
            };
            self.remember_usage(id, Some(usage)).await;
            let running = item.get("State").and_then(Value::as_str) == Some("running");
            if usage.over() && running {
                println!(
                    "{}",
                    serde_json::json!({"volume": "over", "connector": id, "bytes": usage.bytes, "limit_mib": limit_mib})
                );
                self.stop(id, 10).await?;
            }
        }
        Ok(())
    }

    async fn connector_containers(&self) -> Result<Vec<Value>, ApiError> {
        let filter = label_filter(&[
            (MANAGED_BY, MANAGED_BY_VALUE),
            (INSTANCE, &self.instance),
            (ROLE, "connector"),
        ]);
        let reply = self
            .runtime
            .get(&format!("/containers/json?all=true&filters={filter}"))
            .await?;
        Ok(reply.json().as_array().cloned().unwrap_or_default())
    }

    /// Stops every running connector that has a volume, since its size is no longer known.
    async fn stop_unmeasurable(&self, blind: u32, reason: &str) -> Result<(), ApiError> {
        for item in self.connector_containers().await? {
            let Some(id) = item
                .pointer("/Labels")
                .and_then(|l| l.get(CONNECTOR))
                .and_then(Value::as_str)
            else {
                continue;
            };
            let as_inspected = serde_json::json!({"Config": {"Labels": item.get("Labels")}});
            let running = item.get("State").and_then(Value::as_str) == Some("running");
            if running && limit_of(&as_inspected).is_some() {
                println!(
                    "{}",
                    serde_json::json!({"volume": "unmeasurable", "connector": id, "checks": blind, "reason": reason})
                );
                self.stop(id, 10).await?;
            }
        }
        Ok(())
    }
}

/// Runs [`Supervisor::check_volumes`] every [`CHECK_EVERY`] until the process ends.
pub fn spawn_watch(supervisor: Arc<Supervisor>) {
    tokio::spawn(async move {
        loop {
            if let Err(err) = supervisor.check_volumes().await {
                tracing::warn!(reason = err.detail, "measuring connector volumes failed");
            }
            tokio::time::sleep(CHECK_EVERY).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn only_this_instances_volumes_are_measured() {
        let mine = |id: &str, size: i64| json!({"Labels": {MANAGED_BY: MANAGED_BY_VALUE, INSTANCE: "a", ROLE: "volume", CONNECTOR: id}, "UsageData": {"Size": size}});
        let df = json!({"Volumes": [
            mine("one", 5 * MIB as i64),
            mine("unknown", -1),
            {"Labels": {MANAGED_BY: MANAGED_BY_VALUE, INSTANCE: "b", ROLE: "volume", CONNECTOR: "two"}, "UsageData": {"Size": 9}},
            {"Labels": null, "UsageData": {"Size": 9}},
        ]});
        let sizes = sizes_of(&df, "a");
        assert_eq!(sizes.len(), 1);
        assert_eq!(sizes["one"], 5 * MIB);
    }

    #[test]
    fn a_volume_is_over_only_past_its_ceiling() {
        assert!(
            !Usage {
                bytes: MIB,
                limit_mib: 1
            }
            .over()
        );
        assert!(
            Usage {
                bytes: MIB + 1,
                limit_mib: 1
            }
            .over()
        );
        let labelled = |v: &str, mib: Option<&str>| {
            let mut labels = json!({VOLUME: v});
            if let Some(mib) = mib {
                labels[VOLUME_MIB] = json!(mib);
            }
            json!({"Config": {"Labels": labels}})
        };
        assert_eq!(limit_of(&labelled("1", Some("8"))), Some(8));
        assert_eq!(limit_of(&labelled("1", None)), Some(DEFAULT_VOLUME_MIB));
        assert_eq!(limit_of(&labelled("0", Some("8"))), None);
    }

    /// A runtime stand-in: `df` answers or fails, one running connector holds a volume, stops are recorded.
    mod fake_runtime {
        use std::path::PathBuf;
        use std::sync::{Arc, Mutex};

        use axum::Router;
        use axum::extract::State;
        use axum::http::{Method, StatusCode, Uri};
        use axum::response::{IntoResponse, Response};
        use serde_json::json;

        use super::*;

        #[derive(Default)]
        pub struct Docker {
            pub df_fails: bool,
            pub stopped: Vec<String>,
        }

        pub fn labels() -> Value {
            json!({MANAGED_BY: MANAGED_BY_VALUE, INSTANCE: "inst", CONNECTOR: "c1", ROLE: "connector", VOLUME: "1"})
        }

        async fn answer(
            State(docker): State<Arc<Mutex<Docker>>>,
            method: Method,
            uri: Uri,
        ) -> Response {
            let mut docker = docker.lock().unwrap();
            match (method.as_str(), uri.path()) {
                ("GET", "/system/df") if docker.df_fails => {
                    (StatusCode::INTERNAL_SERVER_ERROR, "busy").into_response()
                }
                ("GET", "/system/df") => axum::Json(json!({"Volumes": []})).into_response(),
                ("GET", "/containers/json") => {
                    axum::Json(json!([{"Id": "x", "State": "running", "Labels": labels()}]))
                        .into_response()
                }
                ("GET", "/containers/slimm-c-inst-c1/json") => {
                    axum::Json(json!({"Config": {"Labels": labels()}})).into_response()
                }
                ("POST", path) if path.ends_with("/stop") => {
                    docker.stopped.push(path.to_owned());
                    StatusCode::NO_CONTENT.into_response()
                }
                _ => StatusCode::NOT_FOUND.into_response(),
            }
        }

        pub async fn serve() -> (Arc<Supervisor>, Arc<Mutex<Docker>>, PathBuf) {
            let dir =
                std::env::temp_dir().join(format!("slimm-sup-{}", uuid::Uuid::now_v7().simple()));
            std::fs::create_dir_all(&dir).unwrap();
            let socket = dir.join("runtime.sock");
            let docker = Arc::new(Mutex::new(Docker::default()));
            let listener = tokio::net::UnixListener::bind(&socket).unwrap();
            let app = Router::new().fallback(answer).with_state(docker.clone());
            tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
            let env = [
                (
                    "SLIMM_SUPERVISOR_SECRET",
                    "a-secret-of-at-least-32-characters-x",
                ),
                ("SLIMM_SUPERVISOR_SERVER_URL", "http://server:8080"),
                ("SLIMM_SUPERVISOR_EGRESS_NETWORK", "egress"),
                ("SLIMM_SUPERVISOR_IMAGE", "supervisor:test"),
                ("SLIMM_RUNTIME_SOCKET", socket.to_str().unwrap()),
            ]
            .map(|(k, v)| (k.to_owned(), v.to_owned()))
            .into();
            let config = crate::config::Config::from_map(&env).unwrap();
            (Supervisor::new(config, "inst".to_owned()), docker, dir)
        }
    }

    #[tokio::test]
    async fn connectors_with_a_volume_are_stopped_when_the_sizes_cannot_be_read_for_long() {
        let (supervisor, docker, dir) = fake_runtime::serve().await;
        docker.lock().unwrap().df_fails = true;

        for _ in 1..BLIND_CHECKS_BEFORE_STOPPING {
            assert!(supervisor.check_volumes().await.is_err());
        }
        assert!(
            docker.lock().unwrap().stopped.is_empty(),
            "one slow check is not a reason to stop anything"
        );
        assert!(supervisor.check_volumes().await.is_err());
        assert_eq!(
            docker.lock().unwrap().stopped.len(),
            1,
            "enforcement fails closed"
        );

        docker.lock().unwrap().df_fails = false;
        docker.lock().unwrap().stopped.clear();
        assert!(supervisor.check_volumes().await.is_ok());
        docker.lock().unwrap().df_fails = true;
        assert!(supervisor.check_volumes().await.is_err());
        assert!(
            docker.lock().unwrap().stopped.is_empty(),
            "a check that read the sizes starts the count again"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
