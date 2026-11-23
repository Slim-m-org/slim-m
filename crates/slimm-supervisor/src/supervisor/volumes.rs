// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The data volume ceiling: a named local volume has no size limit of its own, so the
//! supervisor measures each connector's volume on a timer and stops the connector when it is
//! over (decision 0134, amendment of 2026-11-23).

use std::collections::HashMap;
use std::sync::Arc;
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
        let reply = self.runtime.get("/system/df?type=volume").await?;
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
    pub async fn check_volumes(&self) -> Result<(), ApiError> {
        let sizes = self.volume_sizes().await?;
        let filter = label_filter(&[
            (MANAGED_BY, MANAGED_BY_VALUE),
            (INSTANCE, &self.instance),
            (ROLE, "connector"),
        ]);
        let reply = self
            .runtime
            .get(&format!("/containers/json?all=true&filters={filter}"))
            .await?;
        for item in reply.json().as_array().cloned().unwrap_or_default() {
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
}
