// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `connector.host_run` (decision 0134, add-on API 7): a connector that asks the host to run
//! its image. The supervisor enforces the sandbox and the operator's registries and ceilings;
//! this only refuses a manifest that could never be run, so the consent screen is honest.

use serde::Deserialize;

use super::super::{ManifestError, malformed};
use crate::store::{EgressHost, HostRunSpec};

/// The most egress pairs a connector may ask for, as the supervisor allows.
pub(in crate::http) const MAX_EGRESS: usize = 32;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(in crate::http::dock::manifest) struct RawHostRun {
    image: String,
    #[serde(default)]
    egress: Vec<RawEgress>,
    #[serde(default)]
    egress_private: bool,
    #[serde(default)]
    volume: bool,
    #[serde(default)]
    limits: Option<RawLimits>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawEgress {
    host: String,
    port: u16,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawLimits {
    memory_mib: Option<i64>,
    cpus: Option<f64>,
    pids: Option<i64>,
    volume_mib: Option<i64>,
}

/// What the manifest asks the host to run; the admin approves the egress at install.
pub(in crate::http) type ManifestHostRun = HostRunSpec;

pub(in crate::http::dock::manifest) fn validate(
    raw: RawHostRun,
) -> Result<ManifestHostRun, ManifestError> {
    check_image(&raw.image)?;
    if raw.egress.len() > MAX_EGRESS {
        return Err(malformed(
            "connector.host_run.egress names more than 32 hosts",
        ));
    }
    let mut egress = Vec::with_capacity(raw.egress.len());
    for entry in raw.egress {
        let host = normalize_host(&entry.host).ok_or_else(|| {
            malformed("connector.host_run.egress hosts must be host names or IP addresses")
        })?;
        if entry.port == 0 {
            return Err(malformed(
                "connector.host_run.egress ports must be 1 to 65535",
            ));
        }
        let pair = EgressHost {
            host,
            port: entry.port,
        };
        if egress.contains(&pair) {
            return Err(malformed("connector.host_run.egress repeats a host"));
        }
        egress.push(pair);
    }
    let limits = raw.limits.unwrap_or(RawLimits {
        memory_mib: None,
        cpus: None,
        pids: None,
        volume_mib: None,
    });
    let positive = limits.memory_mib.is_none_or(|m| m >= 16)
        && limits.cpus.is_none_or(|c| c.is_finite() && c >= 0.01)
        && limits.pids.is_none_or(|p| p >= 1)
        && limits.volume_mib.is_none_or(|v| v >= 1);
    if !positive {
        return Err(malformed(
            "connector.host_run.limits must be at least 16 MiB, 0.01 CPU, 1 process and a 1 MiB volume",
        ));
    }
    Ok(HostRunSpec {
        image: raw.image,
        egress,
        egress_private: raw.egress_private,
        volume: raw.volume,
        memory_mib: limits.memory_mib,
        cpus: limits.cpus,
        pids: limits.pids,
        volume_mib: limits.volume_mib,
    })
}

/// `<registry>/<path>@sha256:<64 hex>` with no tag, the same rule the supervisor applies.
fn check_image(image: &str) -> Result<(), ManifestError> {
    let refused = || {
        malformed("connector.host_run.image must be <registry>/<path>@sha256:<digest> with no tag")
    };
    let (name, digest) = image.split_once("@sha256:").ok_or_else(refused)?;
    let hex = digest.len() == 64 && digest.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f'));
    let chars = name
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "._-/:".contains(c));
    let last = name.rsplit('/').next().unwrap_or_default();
    let shape =
        name.contains('/') && !last.contains(':') && !name.contains("//") && !name.contains("..");
    if hex && chars && shape {
        Ok(())
    } else {
        Err(refused())
    }
}

/// A lowercase DNS name or a canonical IP literal, as the supervisor normalizes them.
pub(in crate::http) fn normalize_host(host: &str) -> Option<String> {
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        return Some(ip.to_string());
    }
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    let label = |l: &str| {
        !l.is_empty()
            && l.len() <= 63
            && !l.starts_with('-')
            && !l.ends_with('-')
            && l.chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    };
    (!host.is_empty() && host.len() <= 253 && host.split('.').all(label)).then_some(host)
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::super::super::{ManifestError, parse_manifest};

    const IMAGE: &str = "ghcr.io/slim-m-org/jellyfin@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn manifest(host_run: Value) -> Value {
        json!({
            "schema": 1, "id": "jellyfin", "name": "Jellyfin", "version": "0.1.0",
            "summary": "posts what is playing", "provider": "connector", "addon_api": 7,
            "connector": {"permissions": ["send_messages"], "host_run": host_run}
        })
    }

    fn parse(doc: Value) -> Result<super::super::super::Manifest, String> {
        parse_manifest(doc.to_string().as_bytes()).map_err(|ManifestError::Malformed(why)| why)
    }

    #[test]
    fn a_host_run_ask_parses_with_its_egress_and_limits() {
        let doc = manifest(
            json!({"image": IMAGE, "egress": [{"host": "API.Example.com", "port": 443}],
            "egress_private": true, "volume": true, "limits": {"memory_mib": 64, "cpus": 0.25, "pids": 32}}),
        );
        let run = parse(doc).unwrap().connector.unwrap().host_run.unwrap();
        assert_eq!(run.image, IMAGE);
        assert_eq!(run.egress[0].host, "api.example.com");
        assert!(run.egress_private && run.volume);
        assert_eq!(
            (run.memory_mib, run.cpus, run.pids),
            (Some(64), Some(0.25), Some(32))
        );
    }

    #[test]
    fn an_admin_started_connector_has_no_host_run() {
        let mut doc = manifest(json!(null));
        doc["connector"].as_object_mut().unwrap().remove("host_run");
        assert!(parse(doc).unwrap().connector.unwrap().host_run.is_none());
    }

    #[test]
    fn an_image_without_a_digest_or_with_a_tag_is_refused() {
        for image in [
            "ghcr.io/slim-m-org/jellyfin:latest",
            "ghcr.io/slim-m-org/jellyfin",
            "jellyfin@sha256:00",
            "ghcr.io/slim-m-org/jellyfin:1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        ] {
            assert!(
                parse(manifest(json!({"image": image})))
                    .unwrap_err()
                    .contains("image"),
                "{image}"
            );
        }
    }

    #[test]
    fn sandbox_fields_and_bad_egress_are_refused() {
        for extra in [
            json!({"privileged": true}),
            json!({"ports": [80]}),
            json!({"binds": ["/:/host"]}),
            json!({"user": "0"}),
        ] {
            let mut run = json!({"image": IMAGE});
            run.as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            assert!(parse(manifest(run)).is_err(), "{extra}");
        }
        let many: Vec<Value> = (0..33)
            .map(|i| json!({"host": format!("h{i}.com"), "port": 443}))
            .collect();
        assert!(parse(manifest(json!({"image": IMAGE, "egress": many}))).is_err());
        assert!(
            parse(manifest(
                json!({"image": IMAGE, "egress": [{"host": "*", "port": 443}]})
            ))
            .is_err()
        );
        assert!(
            parse(manifest(
                json!({"image": IMAGE, "egress": [{"host": "a.com", "port": 0}]})
            ))
            .is_err()
        );
        assert!(parse(manifest(json!({"image": IMAGE, "limits": {"pids": 0}}))).is_err());
        let twice = json!([{"host": "a.com", "port": 1}, {"host": "A.com", "port": 1}]);
        assert!(parse(manifest(json!({"image": IMAGE, "egress": twice}))).is_err());
    }
}
