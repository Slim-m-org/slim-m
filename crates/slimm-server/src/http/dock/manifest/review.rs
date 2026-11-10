// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A digest of everything an admin's consent is about, so an install can prove
//! it is for the manifest that was reviewed and not one swapped in since.

use serde::Serialize;
use sha2::{Digest, Sha256};

use super::Manifest;
use crate::media::to_hex;
use crate::store::SettingKind;

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
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<&'a crate::module_runtime::DataSchema>,
    /// The words everyone in a call is shown, so a swap after review changes the digest.
    #[serde(skip_serializing_if = "Option::is_none")]
    call_audio: Option<(&'a str, &'a str, Option<&'a str>)>,
    /// Where it stands in front of a message or a permission check, and what it reads there.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    hooks: Vec<(&'a str, &'a str, &'a str, Vec<&'a str>)>,
    /// The commands and apps it adds: kind, name, command, permission and language.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    extension_points: Vec<ExtensionPoint<'a>>,
    /// Each setting's key, type and the hosts a secret may be sent to.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    settings: Vec<(&'a str, SettingKind, Vec<&'a str>)>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    slots: Vec<(&'a str, &'a str)>,
}

type ExtensionPoint<'a> = (
    &'a str,
    &'a str,
    Option<&'a str>,
    Option<&'a str>,
    Option<&'a str>,
);

fn sorted<'a>(items: impl Iterator<Item = &'a str>) -> Vec<&'a str> {
    let mut v: Vec<&str> = items.collect();
    v.sort_unstable();
    v
}

impl Manifest {
    /// Hex sha256 over the artifact, capabilities, hosts, schedules, permission keys, limits,
    /// hooks, extension points, settings and slots, each list in sorted order.
    pub(in crate::http) fn review_digest(&self) -> String {
        let mut schedules: Vec<(&str, u32)> = self
            .schedules
            .iter()
            .map(|s| (s.command.as_str(), s.every_minutes))
            .collect();
        schedules.sort_unstable();
        let limits = &self.runtime.limits;
        let mut hooks: Vec<_> = self
            .platform
            .hooks
            .iter()
            .map(|h| {
                let reads = sorted(h.reads.iter().map(String::as_str));
                (h.kind.as_str(), h.hook.as_str(), h.phase.as_str(), reads)
            })
            .collect();
        hooks.sort_unstable();
        let mut extension_points: Vec<ExtensionPoint> = self
            .extension_points
            .iter()
            .map(|e| {
                (
                    e.kind.as_str(),
                    e.name.as_str(),
                    e.command.as_deref(),
                    e.permission.as_deref(),
                    e.language.as_deref(),
                )
            })
            .collect();
        extension_points.sort_unstable();
        let mut settings: Vec<_> = self
            .platform
            .settings_schema
            .iter()
            .map(|d| {
                let hosts = sorted(d.hosts.iter().map(String::as_str));
                (d.key.as_str(), d.kind, hosts)
            })
            .collect();
        settings.sort_unstable_by_key(|setting| setting.0);
        let mut slots: Vec<_> = self
            .platform
            .slots
            .iter()
            .map(|s| (s.kind.as_str(), s.name.as_str()))
            .collect();
        slots.sort_unstable();
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
            data: self.data.as_ref(),
            call_audio: self.call_audio.as_ref().map(|c| {
                (
                    c.purpose.as_str(),
                    c.keeps.as_str(),
                    c.permission.as_deref(),
                )
            }),
            hooks,
            extension_points,
            settings,
            slots,
        };
        let json = serde_json::to_vec(&reviewed).unwrap_or_default();
        to_hex(&Sha256::digest(json))
    }
}

#[cfg(test)]
mod tests;
