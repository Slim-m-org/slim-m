// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The manifest's `network` section: the hosts `net.fetch` may reach, shown
//! to the admin at install, and whether the module wants local addresses
//! (which needs the admin's second approval).

use serde::Deserialize;

use super::{ManifestError, malformed};

/// The capability this section belongs to.
pub(in crate::http) const NET_FETCH: &str = "net.fetch";
/// Most hosts a module may list; a short list is one an admin can read.
const MAX_HOSTS: usize = 16;
/// The longest DNS name.
const MAX_HOST_LEN: usize = 253;

#[derive(Deserialize, Default)]
pub(super) struct RawNetwork {
    #[serde(default)]
    hosts: Vec<String>,
    #[serde(default)]
    local: bool,
}

/// Hosts are lowercase `name` or `name:port`; empty when the module declares
/// no `net.fetch`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(in crate::http) struct ManifestNetwork {
    pub(in crate::http) hosts: Vec<String>,
    pub(in crate::http) local: bool,
}

/// `net.fetch` and a host list come together or not at all: a capability with
/// nowhere to go, or hosts nothing can reach, both mean the manifest is wrong.
pub(super) fn validate_network(
    raw: Option<RawNetwork>,
    capabilities: &[String],
) -> Result<ManifestNetwork, ManifestError> {
    let raw = raw.unwrap_or_default();
    let declares_fetch = capabilities.iter().any(|c| c == NET_FETCH);
    if declares_fetch && raw.hosts.is_empty() {
        return Err(malformed("net.fetch needs network.hosts"));
    }
    if !declares_fetch && (!raw.hosts.is_empty() || raw.local) {
        return Err(malformed(
            "network is only meaningful with the net.fetch capability",
        ));
    }
    if raw.hosts.len() > MAX_HOSTS {
        return Err(malformed("manifest lists too many network hosts"));
    }
    let mut hosts: Vec<String> = Vec::with_capacity(raw.hosts.len());
    for host in raw.hosts {
        let host = host.to_ascii_lowercase();
        if !is_host_entry(&host) {
            return Err(malformed(
                "network.hosts entries must be a host name or host:port",
            ));
        }
        if !hosts.contains(&host) {
            hosts.push(host);
        }
    }
    Ok(ManifestNetwork {
        hosts,
        local: raw.local,
    })
}

/// A DNS name or IPv4 address, optionally with a port: no scheme, path,
/// wildcard or credentials, so the admin sees exactly where data can go.
fn is_host_entry(entry: &str) -> bool {
    let (name, port) = match entry.rsplit_once(':') {
        Some((name, port)) => (name, Some(port)),
        None => (entry, None),
    };
    if port.is_some_and(|p| p.parse::<u16>().map_or(true, |p| p == 0)) {
        return false;
    }
    !name.is_empty()
        && name.len() <= MAX_HOST_LEN
        && name.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn caps(list: &[&str]) -> Vec<String> {
        list.iter().map(|c| c.to_string()).collect()
    }

    fn raw(hosts: &[&str], local: bool) -> Option<RawNetwork> {
        Some(RawNetwork {
            hosts: hosts.iter().map(|h| h.to_string()).collect(),
            local,
        })
    }

    #[test]
    fn net_fetch_and_hosts_come_together() {
        assert!(validate_network(raw(&[], false), &caps(&["net.fetch"])).is_err());
        assert!(validate_network(raw(&["a.example"], false), &caps(&[])).is_err());
        assert!(validate_network(raw(&[], true), &caps(&[])).is_err());
        assert_eq!(
            validate_network(None, &caps(&["kv.store"])).unwrap(),
            ManifestNetwork::default()
        );
    }

    #[test]
    fn hosts_are_lowercased_and_deduplicated() {
        let net = validate_network(
            raw(
                &["API.Example.com", "api.example.com", "jellyfin.lan:8096"],
                true,
            ),
            &caps(&["net.fetch"]),
        )
        .unwrap();
        assert_eq!(net.hosts, vec!["api.example.com", "jellyfin.lan:8096"]);
        assert!(net.local);
    }

    #[test]
    fn anything_but_a_plain_host_is_refused() {
        for bad in [
            "https://api.example.com",
            "api.example.com/path",
            "*.example.com",
            "user@api.example.com",
            "api.example.com:0",
            "api.example.com:99999",
            "-bad.example",
            "",
            "[::1]:80",
        ] {
            assert!(
                validate_network(raw(&[bad], false), &caps(&["net.fetch"])).is_err(),
                "{bad}"
            );
        }
    }
}
