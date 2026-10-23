// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A digest of everything an admin's consent is about, so an install can prove
//! it is for the manifest that was reviewed and not one swapped in since.

use serde::Serialize;
use sha2::{Digest, Sha256};

use super::Manifest;
use crate::media::to_hex;

#[derive(Serialize)]
struct Reviewed<'a> {
    id: &'a str,
    version: &'a str,
    artifact_sha256: &'a str,
    capabilities: Vec<&'a str>,
    hosts: Vec<&'a str>,
    local: bool,
    schedules: Vec<(&'a str, u32)>,
    permissions: Vec<&'a str>,
    limits: (Option<u64>, Option<u64>, Option<u64>),
    #[serde(skip_serializing_if = "Vec::is_empty")]
    subscriptions: Vec<&'a str>,
    #[serde(skip_serializing_if = "serde_json::Value::is_null")]
    data: &'a serde_json::Value,
}

fn sorted<'a>(items: impl Iterator<Item = &'a str>) -> Vec<&'a str> {
    let mut v: Vec<&str> = items.collect();
    v.sort_unstable();
    v
}

impl Manifest {
    /// Hex sha256 over the artifact, capabilities, hosts, schedules,
    /// permission keys and limits, each list in sorted order.
    pub(in crate::http) fn review_digest(&self) -> String {
        let mut schedules: Vec<(&str, u32)> = self
            .schedules
            .iter()
            .map(|s| (s.command.as_str(), s.every_minutes))
            .collect();
        schedules.sort_unstable();
        let limits = &self.runtime.limits;
        let reviewed = Reviewed {
            id: &self.id,
            version: &self.version,
            artifact_sha256: &self.artifact.sha256,
            capabilities: sorted(self.capabilities.iter().map(String::as_str)),
            hosts: sorted(self.network.hosts.iter().map(String::as_str)),
            local: self.network.local,
            schedules,
            permissions: sorted(self.permissions.iter().map(|p| p.key.as_str())),
            limits: (limits.memory_mb, limits.wall_ms, limits.fuel),
            subscriptions: sorted(self.platform.subscriptions.iter().map(String::as_str)),
            data: &self.platform.data_schema,
        };
        let json = serde_json::to_vec(&reviewed).unwrap_or_default();
        to_hex(&Sha256::digest(json))
    }
}
