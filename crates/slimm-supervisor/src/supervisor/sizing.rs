// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Sizing a connector volume by the disk it occupies, with a one-shot from the supervisor's own image.

use serde_json::Value;

use super::Supervisor;
use super::volumes::MIB;
use crate::error::ApiError;
use crate::logs;
use crate::runtime::encode;
use crate::sandbox::{self, Names};

impl Supervisor {
    /// Allocated bytes in the connector's volume, or 0 when it has none yet. An answer that never
    /// came is an error, never a size, so an unmeasured volume cannot read as an empty one.
    pub(super) async fn allocated_bytes(
        &self,
        names: &Names,
        limit_mib: u64,
    ) -> Result<u64, ApiError> {
        if !self.volume_exists(names).await? {
            return Ok(0);
        }
        let _one_at_a_time = self.measuring.lock().await;
        self.remove_container(&names.measure, names, "measure")
            .await?;
        let body = sandbox::measure_container(names, &self.pinned_image().await?, limit_mib * MIB);
        self.create_container(&names.measure, &body).await?;
        let sized = self.run_measure(&names.measure).await;
        let _ = self
            .remove_container(&names.measure, names, "measure")
            .await;
        sized
    }

    async fn run_measure(&self, name: &str) -> Result<u64, ApiError> {
        self.start_container(name).await?;
        let waited = self
            .runtime
            .post(&format!("/containers/{}/wait", encode(name)), None)
            .await?;
        if waited.json().get("StatusCode").and_then(Value::as_i64) != Some(0) {
            return Err(ApiError::runtime(format!(
                "measuring the volume failed ({})",
                waited.message()
            )));
        }
        let reply = self
            .runtime
            .get(&format!(
                "/containers/{}/logs?stdout=1&stderr=0&timestamps=1",
                encode(name)
            ))
            .await?;
        logs::demux(&reply.body)
            .iter()
            .find_map(|line| line.text.strip_prefix("allocated=")?.parse().ok())
            .ok_or_else(|| ApiError::runtime("the volume measurement reported no size"))
    }
}
