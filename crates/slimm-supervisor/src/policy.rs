// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The create body is the whole of what the server may choose (decision 0134); this module
//! parses it with unknown fields refused and checks it against the operator's policy.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::config::Ceilings;
use crate::error::ApiError;
use crate::net::{HostPort, normalize_host};

pub const DEFAULT_MEMORY_MIB: u64 = 128;
pub const DEFAULT_CPUS: f64 = 0.5;
pub const DEFAULT_PIDS: u64 = 64;
pub const MIN_MEMORY_MIB: u64 = 16;
pub const DEFAULT_VOLUME_MIB: u64 = 256;
pub const MAX_EGRESS: usize = 32;
pub const MAX_ENV_VALUE: usize = 4 * 1024;
pub const MAX_ENV_TOTAL: usize = 16 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateRequest {
    pub image: String,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub limits: LimitsRequest,
    #[serde(default)]
    pub egress: Vec<HostPort>,
    #[serde(default)]
    pub egress_private: bool,
    #[serde(default)]
    pub volume: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LimitsRequest {
    pub memory_mib: Option<u64>,
    pub cpus: Option<f64>,
    pub pids: Option<u64>,
    pub volume_mib: Option<u64>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StopRequest {
    pub timeout_s: Option<u64>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemoveRequest {
    #[serde(default)]
    pub keep_volume: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StartRequest {}

/// A create body that passed every check, with defaults filled in.
#[derive(Clone, PartialEq, Serialize)]
pub struct Spec {
    pub image: String,
    pub env: BTreeMap<String, String>,
    pub memory_mib: u64,
    pub cpus: f64,
    pub pids: u64,
    pub egress: Vec<HostPort>,
    pub egress_private: bool,
    pub volume: bool,
    /// The data volume's byte ceiling in MiB, which the supervisor's volume watch enforces.
    pub volume_mib: u64,
}

impl std::fmt::Debug for Spec {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Spec")
            .field("image", &self.image)
            .field("env_keys", &self.env.keys().collect::<Vec<_>>())
            .field("egress", &self.egress)
            .finish_non_exhaustive()
    }
}

impl Spec {
    /// Tells a repeated create from a different one; the token in `env` makes it unguessable.
    pub fn fingerprint(&self) -> String {
        let canonical = serde_json::to_vec(self).unwrap_or_default();
        hex(&Sha256::digest(canonical))
    }

    pub fn nano_cpus(&self) -> i64 {
        (self.cpus * 1e9).round() as i64
    }
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Parses a JSON body, refusing unknown fields; an empty body reads as `{}`.
pub fn parse_body<T: serde::de::DeserializeOwned>(body: &[u8]) -> Result<T, ApiError> {
    let body = if body.iter().all(u8::is_ascii_whitespace) {
        b"{}".as_slice()
    } else {
        body
    };
    serde_json::from_slice(body).map_err(|err| ApiError::bad_request(err.to_string()))
}

/// The connector id is the server's UUID, in canonical lowercase form.
pub fn connector_id(raw: &str) -> Result<String, ApiError> {
    match uuid::Uuid::parse_str(raw) {
        Ok(id) if id.hyphenated().to_string() == raw => Ok(raw.to_owned()),
        _ => Err(ApiError::bad_request(
            "connector id must be a lowercase hyphenated UUID",
        )),
    }
}

pub fn validate(
    req: CreateRequest,
    registries: &[String],
    ceilings: &Ceilings,
) -> Result<Spec, ApiError> {
    check_image(&req.image, registries)?;
    check_env(&req.env)?;
    let (memory_mib, cpus, pids) = check_limits(&req.limits, ceilings)?;
    let egress = check_egress(req.egress)?;
    let volume_mib = check_volume(&req.limits, ceilings)?;
    Ok(Spec {
        image: req.image,
        env: req.env,
        memory_mib,
        cpus,
        pids,
        egress,
        egress_private: req.egress_private,
        volume: req.volume,
        volume_mib,
    })
}

/// Defaults like the other limits; a value above the ceiling is `limit`, never clamped.
pub fn check_volume(limits: &LimitsRequest, ceilings: &Ceilings) -> Result<u64, ApiError> {
    let volume = limits.volume_mib.unwrap_or(DEFAULT_VOLUME_MIB);
    if volume == 0 {
        return Err(ApiError::bad_request("volume_mib must be at least 1"));
    }
    if volume > ceilings.max_volume_mib {
        return Err(ApiError::limit(format!(
            "volume_mib {volume} is over the ceiling of {}",
            ceilings.max_volume_mib
        )));
    }
    Ok(volume)
}

/// `<registry>/<path>@sha256:<64 hex>` with no tag, under an allowed prefix.
pub fn check_image(image: &str, registries: &[String]) -> Result<(), ApiError> {
    let (name, digest) = image.split_once("@sha256:").ok_or_else(|| {
        ApiError::policy("image must be pinned by digest: <registry>/<path>@sha256:<digest>")
    })?;
    let hex_ok = digest.len() == 64 && digest.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f'));
    if !hex_ok {
        return Err(ApiError::policy(
            "image digest must be 64 lowercase hex characters",
        ));
    }
    let chars_ok = name
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "._-/:".contains(c));
    let last = name.rsplit('/').next().unwrap_or_default();
    if !chars_ok
        || !name.contains('/')
        || last.contains(':')
        || name.contains("//")
        || name.contains("..")
    {
        return Err(ApiError::policy(
            "image must be <registry>/<path>@sha256:<digest> with no tag",
        ));
    }
    if !registries
        .iter()
        .any(|prefix| name.starts_with(prefix.as_str()))
    {
        return Err(ApiError::policy(format!(
            "image is not under an allowed registry prefix ({})",
            registries.join(", ")
        )));
    }
    Ok(())
}

pub fn check_env(env: &BTreeMap<String, String>) -> Result<(), ApiError> {
    let mut total = 0;
    for (key, value) in env {
        let suffix = key.strip_prefix("SLIMM_").unwrap_or_default();
        let key_ok = (1..=48).contains(&suffix.len())
            && suffix
                .chars()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_');
        if !key_ok {
            return Err(ApiError::policy(format!(
                "env key {key:?} must match SLIMM_[A-Z0-9_]{{1,48}}"
            )));
        }
        if value.len() > MAX_ENV_VALUE || value.contains('\0') {
            return Err(ApiError::policy(format!(
                "env value for {key} is over 4 KiB or holds a NUL"
            )));
        }
        total += value.len();
    }
    if total > MAX_ENV_TOTAL {
        return Err(ApiError::policy("env values are over 16 KiB in total"));
    }
    Ok(())
}

/// Defaults apply only to absent fields; a value above a ceiling is `limit`, never clamped.
pub fn check_limits(
    limits: &LimitsRequest,
    ceilings: &Ceilings,
) -> Result<(u64, f64, u64), ApiError> {
    let memory = limits.memory_mib.unwrap_or(DEFAULT_MEMORY_MIB);
    let cpus = limits.cpus.unwrap_or(DEFAULT_CPUS);
    let pids = limits.pids.unwrap_or(DEFAULT_PIDS);
    if memory < MIN_MEMORY_MIB || !(cpus.is_finite() && cpus >= 0.01) || pids == 0 {
        return Err(ApiError::bad_request(
            "limits must be at least 16 MiB, 0.01 CPU and 1 process",
        ));
    }
    if memory > ceilings.max_memory_mib {
        return Err(ApiError::limit(format!(
            "memory_mib {memory} is over the ceiling of {}",
            ceilings.max_memory_mib
        )));
    }
    if cpus > ceilings.max_cpus {
        return Err(ApiError::limit(format!(
            "cpus {cpus} is over the ceiling of {}",
            ceilings.max_cpus
        )));
    }
    if pids > ceilings.max_pids {
        return Err(ApiError::limit(format!(
            "pids {pids} is over the ceiling of {}",
            ceilings.max_pids
        )));
    }
    Ok((memory, cpus, pids))
}

pub fn check_egress(egress: Vec<HostPort>) -> Result<Vec<HostPort>, ApiError> {
    if egress.len() > MAX_EGRESS {
        return Err(ApiError::policy(format!(
            "at most {MAX_EGRESS} egress entries"
        )));
    }
    let mut out = Vec::with_capacity(egress.len());
    for entry in egress {
        let host = normalize_host(&entry.host).ok_or_else(|| {
            ApiError::policy(format!(
                "egress host {:?} is not a host name or IP",
                entry.host
            ))
        })?;
        if entry.port == 0 {
            return Err(ApiError::policy("egress port must be 1 to 65535"));
        }
        out.push(HostPort {
            host,
            port: entry.port,
        });
    }
    out.sort();
    out.dedup();
    Ok(out)
}

#[cfg(test)]
mod tests;
