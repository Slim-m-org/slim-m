// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The operator's configuration, read once from the environment at start.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::Serialize;

use crate::net::{Cidr, HostPort};

/// The shortest bearer secret the supervisor accepts (decision 0134).
pub const MIN_SECRET_LEN: usize = 32;

/// Per-connector ceilings and the connector count cap.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Ceilings {
    pub max_connectors: usize,
    pub max_memory_mib: u64,
    pub max_cpus: f64,
    pub max_pids: u64,
}

impl Default for Ceilings {
    fn default() -> Self {
        Self {
            max_connectors: 8,
            max_memory_mib: 512,
            max_cpus: 1.0,
            max_pids: 256,
        }
    }
}

/// Everything the supervisor needs, validated.
#[derive(Clone)]
pub struct Config {
    pub socket: PathBuf,
    pub secret: String,
    pub server_uid: u32,
    pub runtime_socket: PathBuf,
    pub registries: Vec<String>,
    pub ceilings: Ceilings,
    pub server: HostPort,
    pub egress_network: String,
    pub lan_deny: Vec<Cidr>,
    pub state_dir: PathBuf,
    pub own_image: String,
}

impl std::fmt::Debug for Config {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Config")
            .field("socket", &self.socket)
            .field("secret", &"<redacted>")
            .field("server_uid", &self.server_uid)
            .field("registries", &self.registries)
            .field("ceilings", &self.ceilings)
            .finish_non_exhaustive()
    }
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        Self::from_map(&std::env::vars().collect())
    }

    pub fn from_map(env: &HashMap<String, String>) -> Result<Self, String> {
        let get = |key: &str| env.get(key).map(|v| v.trim()).filter(|v| !v.is_empty());
        let secret = env
            .get("SLIMM_SUPERVISOR_SECRET")
            .cloned()
            .unwrap_or_default();
        if secret.chars().count() < MIN_SECRET_LEN {
            return Err(format!(
                "SLIMM_SUPERVISOR_SECRET must be at least {MIN_SECRET_LEN} characters"
            ));
        }
        let server_url = get("SLIMM_SUPERVISOR_SERVER_URL")
            .ok_or("SLIMM_SUPERVISOR_SERVER_URL is required (for example http://server:8080)")?;
        let server = HostPort::from_http_url(server_url)
            .ok_or("SLIMM_SUPERVISOR_SERVER_URL must be http://host:port")?;
        let egress_network = get("SLIMM_SUPERVISOR_EGRESS_NETWORK")
            .ok_or("SLIMM_SUPERVISOR_EGRESS_NETWORK is required")?
            .to_owned();
        let own_image = get("SLIMM_SUPERVISOR_IMAGE")
            .ok_or("SLIMM_SUPERVISOR_IMAGE is required: the supervisor's own image, for gateways")?
            .to_owned();
        let defaults = Ceilings::default();
        let ceilings = Ceilings {
            max_connectors: parse_or(
                get("SLIMM_SUPERVISOR_MAX_CONNECTORS"),
                defaults.max_connectors,
            )?,
            max_memory_mib: parse_or(
                get("SLIMM_SUPERVISOR_MAX_MEMORY_MIB"),
                defaults.max_memory_mib,
            )?,
            max_cpus: parse_or(get("SLIMM_SUPERVISOR_MAX_CPUS"), defaults.max_cpus)?,
            max_pids: parse_or(get("SLIMM_SUPERVISOR_MAX_PIDS"), defaults.max_pids)?,
        };
        if !(ceilings.max_cpus.is_finite() && ceilings.max_cpus > 0.0) {
            return Err("SLIMM_SUPERVISOR_MAX_CPUS must be a positive number".into());
        }
        Ok(Self {
            socket: get("SLIMM_SUPERVISOR_SOCKET")
                .unwrap_or("/run/slimm-supervisor/supervisor.sock")
                .into(),
            secret,
            server_uid: parse_or(get("SLIMM_SUPERVISOR_SERVER_UID"), 65532)?,
            runtime_socket: get("SLIMM_RUNTIME_SOCKET")
                .unwrap_or("/run/runtime.sock")
                .into(),
            registries: parse_registries(
                get("SLIMM_SUPERVISOR_REGISTRIES").unwrap_or("ghcr.io/slim-m-org/"),
            )?,
            ceilings,
            server,
            egress_network,
            lan_deny: parse_cidrs(get("SLIMM_SUPERVISOR_LAN_DENY").unwrap_or(""))?,
            state_dir: get("SLIMM_SUPERVISOR_STATE_DIR")
                .unwrap_or("/var/lib/slimm-supervisor")
                .into(),
            own_image,
        })
    }
}

fn parse_or<T: std::str::FromStr>(raw: Option<&str>, default: T) -> Result<T, String> {
    raw.map_or(Ok(default), |v| {
        v.parse()
            .map_err(|_| format!("{v:?} is not a valid number"))
    })
}

/// Each prefix names at least a registry and an owner, so `ghcr.io/` alone is refused.
pub fn parse_registries(raw: &str) -> Result<Vec<String>, String> {
    let prefixes: Vec<String> = raw
        .split(',')
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(|p| {
            if p.ends_with('/') {
                p.to_owned()
            } else {
                format!("{p}/")
            }
        })
        .collect();
    if prefixes.is_empty() {
        return Err("SLIMM_SUPERVISOR_REGISTRIES names no registry".into());
    }
    for prefix in &prefixes {
        let parts: Vec<&str> = prefix.trim_end_matches('/').split('/').collect();
        let bad_char = prefix
            .chars()
            .any(|c| !(c.is_ascii_lowercase() || c.is_ascii_digit() || "._-/:".contains(c)));
        if parts.len() < 2 || parts.iter().any(|p| p.is_empty()) || bad_char {
            return Err(format!(
                "registry prefix {prefix:?} must be <registry>/<owner>/"
            ));
        }
    }
    Ok(prefixes)
}

fn parse_cidrs(raw: &str) -> Result<Vec<Cidr>, String> {
    raw.split(',')
        .map(str::trim)
        .filter(|e| !e.is_empty())
        .map(|e| {
            Cidr::parse(e).ok_or_else(|| {
                format!("SLIMM_SUPERVISOR_LAN_DENY entry {e:?} is not an IP or CIDR")
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> HashMap<String, String> {
        [
            ("SLIMM_SUPERVISOR_SECRET", "s".repeat(32).as_str()),
            ("SLIMM_SUPERVISOR_SERVER_URL", "http://server:8080"),
            ("SLIMM_SUPERVISOR_EGRESS_NETWORK", "slimm_connectors_egress"),
            (
                "SLIMM_SUPERVISOR_IMAGE",
                "ghcr.io/slim-m-org/slim-m-supervisor:latest",
            ),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect()
    }

    #[test]
    fn defaults_match_the_decision() {
        let config = Config::from_map(&base()).unwrap();
        assert_eq!(config.ceilings, Ceilings::default());
        assert_eq!(config.registries, vec!["ghcr.io/slim-m-org/".to_owned()]);
        assert_eq!(config.server_uid, 65532);
        assert_eq!(config.server, HostPort::new("server", 8080));
    }

    #[test]
    fn a_short_secret_refuses_to_start() {
        let mut env = base();
        env.insert("SLIMM_SUPERVISOR_SECRET".into(), "s".repeat(31));
        assert!(Config::from_map(&env).unwrap_err().contains("at least 32"));
        env.remove("SLIMM_SUPERVISOR_SECRET");
        assert!(Config::from_map(&env).is_err());
    }

    #[test]
    fn a_bare_registry_is_not_a_prefix() {
        assert!(parse_registries("ghcr.io/").is_err());
        assert!(parse_registries("ghcr.io").is_err());
        assert!(parse_registries("GHCR.io/Org/").is_err());
        assert_eq!(
            parse_registries("localhost:5000/test").unwrap(),
            vec!["localhost:5000/test/"]
        );
    }

    #[test]
    fn the_debug_form_hides_the_secret() {
        let config = Config::from_map(&base()).unwrap();
        assert!(!format!("{config:?}").contains(&"s".repeat(32)));
    }

    #[test]
    fn a_bad_deny_entry_refuses_to_start() {
        let mut env = base();
        env.insert(
            "SLIMM_SUPERVISOR_LAN_DENY".into(),
            "10.0.0.0/8, nonsense".into(),
        );
        assert!(Config::from_map(&env).is_err());
    }
}
