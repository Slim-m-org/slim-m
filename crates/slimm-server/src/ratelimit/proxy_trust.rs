// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which TCP peers may say who the caller is (`SLIMM_TRUSTED_PROXIES`): a forwarded
//! header from any other peer is ignored, whatever `SLIMM_TRUST_PROXY_HOPS` says.

use std::net::IpAddr;

use crate::net_guard::Cidr;

/// Loopback and the private ranges, where a compose or LAN reverse proxy sits.
pub const DEFAULT_TRUSTED_PROXIES: &str =
    "127.0.0.0/8,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7";

/// Ranges a forwarding peer must be in, and `!`-prefixed ranges it must not be in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProxyTrust {
    trusted: Vec<Cidr>,
    excluded: Vec<Cidr>,
}

impl Default for ProxyTrust {
    fn default() -> Self {
        Self::parse(DEFAULT_TRUSTED_PROXIES).expect("the default list parses")
    }
}

impl ProxyTrust {
    /// `10.0.0.0/8,::1,!10.213.254.0/24`; an entry that is not an IP or CIDR refuses the whole list.
    pub fn parse(raw: &str) -> Result<Self, String> {
        let mut trust = Self {
            trusted: Vec::new(),
            excluded: Vec::new(),
        };
        for entry in raw.split(',').map(str::trim).filter(|e| !e.is_empty()) {
            let (list, text) = match entry.strip_prefix('!') {
                Some(rest) => (&mut trust.excluded, rest.trim()),
                None => (&mut trust.trusted, entry),
            };
            let cidr = Cidr::parse(text).ok_or_else(|| {
                format!("SLIMM_TRUSTED_PROXIES entry {entry:?} is not an IP or CIDR")
            })?;
            list.push(cidr);
        }
        Ok(trust)
    }

    /// The setting's value, or the default when it is unset or blank.
    pub fn from_setting(raw: Option<&str>) -> Result<Self, String> {
        match raw.map(str::trim).filter(|r| !r.is_empty()) {
            Some(raw) => Self::parse(raw),
            None => Ok(Self::default()),
        }
    }

    pub fn trusts(&self, peer: IpAddr) -> bool {
        self.trusted.iter().any(|c| c.contains(peer))
            && !self.excluded.iter().any(|c| c.contains(peer))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    #[test]
    fn the_default_trusts_loopback_and_private_peers_only() {
        let trust = ProxyTrust::default();
        for peer in [
            "127.0.0.1",
            "::1",
            "10.1.2.3",
            "172.18.0.4",
            "192.168.1.9",
            "fd00::7",
        ] {
            assert!(trust.trusts(ip(peer)), "{peer}");
        }
        for peer in [
            "203.0.113.7",
            "2001:db8::1",
            "100.64.0.1",
            "169.254.169.254",
        ] {
            assert!(!trust.trusts(ip(peer)), "{peer}");
        }
        assert!(trust.trusts(ip("::ffff:10.0.0.1")));
    }

    #[test]
    fn an_excluded_range_wins_over_a_trusted_one() {
        let trust = ProxyTrust::parse("10.0.0.0/8, !10.213.254.0/24").unwrap();
        assert!(trust.trusts(ip("10.0.0.5")));
        assert!(!trust.trusts(ip("10.213.254.3")));
    }

    #[test]
    fn a_bad_entry_refuses_the_list_and_blank_means_the_default() {
        assert!(ProxyTrust::parse("10.0.0.0/8,nonsense").is_err());
        assert!(ProxyTrust::parse("!").is_err());
        assert_eq!(
            ProxyTrust::from_setting(Some("  ")).unwrap(),
            ProxyTrust::default()
        );
        assert!(
            !ProxyTrust::from_setting(Some("192.0.2.1"))
                .unwrap()
                .trusts(ip("10.0.0.1"))
        );
    }
}
