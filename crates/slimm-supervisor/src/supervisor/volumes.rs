// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The data volume ceiling: a named local volume has no size limit of its own, so the
//! supervisor measures each connector's volume on a timer and stops the connector when it is
//! over (decision 0134, amendment of 2026-11-23).

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
pub(super) const MIB: u64 = 1024 * 1024;
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
    /// The usage of one connector's volume measured now, or `None` when it has none.
    pub(super) async fn measure(
        &self,
        id: &str,
        inspected: &Value,
    ) -> Result<Option<Usage>, ApiError> {
        let Some(limit_mib) = limit_of(inspected) else {
            return Ok(None);
        };
        let bytes = self.allocated_bytes(&self.names(id), limit_mib).await?;
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
    /// A volume that could not be measured counts as blind; after enough blind checks in a row
    /// the connectors that could not be measured are stopped, since their size is unknown.
    /// A failing stop is logged and the sweep goes on; the first error is returned at the end.
    pub async fn check_volumes(&self) -> Result<(), ApiError> {
        let mut first_error = None;
        let mut blind = Vec::new();
        for item in self.connector_containers().await? {
            let Some((id, limit_mib, running)) = volume_holder(&item) else {
                continue;
            };
            match self.allocated_bytes(&self.names(id), limit_mib).await {
                Ok(bytes) => {
                    let usage = Usage { bytes, limit_mib };
                    self.remember_usage(id, Some(usage)).await;
                    if usage.over() && running {
                        println!(
                            "{}",
                            serde_json::json!({"volume": "over", "connector": id, "bytes": bytes, "limit_mib": limit_mib})
                        );
                        self.stop_noting(id, &mut first_error).await;
                    }
                }
                Err(err) => {
                    if running {
                        blind.push((id.to_owned(), err.detail.clone()));
                    }
                    first_error.get_or_insert(err);
                }
            }
        }
        if first_error.is_none() {
            self.blind_checks.store(0, Ordering::Relaxed);
        } else {
            let checks = self.blind_checks.fetch_add(1, Ordering::Relaxed) + 1;
            if checks >= BLIND_CHECKS_BEFORE_STOPPING {
                for (id, reason) in blind {
                    println!(
                        "{}",
                        serde_json::json!({"volume": "unmeasurable", "connector": id, "checks": checks, "reason": reason})
                    );
                    self.stop_noting(&id, &mut first_error).await;
                }
            }
        }
        first_error.map_or(Ok(()), Err)
    }

    async fn stop_noting(&self, id: &str, first_error: &mut Option<ApiError>) {
        if let Err(err) = self.stop(id, 10).await {
            tracing::warn!(
                connector = id,
                reason = err.detail,
                "stopping a connector over its volume ceiling failed"
            );
            first_error.get_or_insert(err);
        }
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
}

/// The connector id, volume ceiling and running flag of a container that has a data volume.
fn volume_holder(item: &Value) -> Option<(&str, u64, bool)> {
    let id = item.pointer("/Labels")?.get(CONNECTOR)?.as_str()?;
    let as_inspected = serde_json::json!({"Config": {"Labels": item.get("Labels")}});
    let limit_mib = limit_of(&as_inspected)?;
    let running = item.get("State").and_then(Value::as_str) == Some("running");
    Some((id, limit_mib, running))
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
}
