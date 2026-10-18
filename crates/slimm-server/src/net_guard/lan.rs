// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one thing a module's local network approval lifts: private LAN
//! ranges (10/8, 172.16/12, 192.168/16, fc00::/7). Loopback, link-local, the
//! cloud metadata address and everything else [`super::is_blocked`] refuses
//! stay refused, and so do the server's own addresses and the Docker bridge
//! it sits on, which are private ranges too but are not "a device at home".

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};

use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use tokio::net::lookup_host;

use super::is_blocked;

/// Lets an integration test dial the loopback listener a fake upstream binds to.
static LOOPBACK_AS_LAN_FOR_TESTS: AtomicBool = AtomicBool::new(false);

/// Test seam only: no production path calls it.
#[doc(hidden)]
pub fn treat_loopback_as_lan_for_tests(on: bool) {
    LOOPBACK_AS_LAN_FOR_TESTS.store(on, Ordering::SeqCst);
}

/// Addresses that are the server itself or its container network, which a
/// private range would otherwise admit.
#[derive(Debug, Default, Clone)]
pub struct OwnAddresses {
    exact: Vec<IpAddr>,
    docker_bridges: Vec<[u8; 2]>,
}

impl OwnAddresses {
    pub fn new(addresses: impl IntoIterator<Item = IpAddr>) -> Self {
        let exact: Vec<IpAddr> = addresses.into_iter().collect();
        let docker_bridges = exact
            .iter()
            .filter_map(|ip| match ip {
                IpAddr::V4(v4) if in_docker_range(*v4) => Some([v4.octets()[0], v4.octets()[1]]),
                _ => None,
            })
            .collect();
        Self {
            exact,
            docker_bridges,
        }
    }

    /// What this host answers on right now, read from the kernel on Linux.
    pub fn detect() -> Self {
        let mut found = local_ipv4s("/proc/net/fib_trie");
        found.extend(default_gateway("/proc/net/route"));
        Self::new(found.into_iter().map(IpAddr::V4))
    }

    fn covers(&self, ip: IpAddr) -> bool {
        if self.exact.contains(&ip) {
            return true;
        }
        match ip {
            IpAddr::V4(v4) => self
                .docker_bridges
                .contains(&[v4.octets()[0], v4.octets()[1]]),
            IpAddr::V6(_) => false,
        }
    }
}

/// Docker's default bridge networks live in 172.16/12.
fn in_docker_range(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    a == 172 && (16..32).contains(&b)
}

fn is_lan(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_lan_v4(v4),
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => is_lan_v4(v4),
            None => (v6.segments()[0] & 0xfe00) == 0xfc00,
        },
    }
}

fn is_lan_v4(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    a == 10 || in_docker_range(ip) || (a == 192 && b == 168)
}

fn unmapped(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(ip, IpAddr::V4),
        IpAddr::V4(_) => ip,
    }
}

/// Whether a module holding the local network approval may dial `ip`: any
/// public address, or a private LAN address that is not this server's own.
pub fn allowed_with_local_approval(ip: IpAddr, own: &OwnAddresses) -> bool {
    if LOOPBACK_AS_LAN_FOR_TESTS.load(Ordering::SeqCst) && ip.is_loopback() {
        return true;
    }
    if !is_blocked(ip) {
        return true;
    }
    is_lan(ip) && !own.covers(unmapped(ip))
}

/// As [`super::GuardResolver`], but lifting only the private LAN ranges.
pub struct LanGuardResolver;

impl Resolve for LanGuardResolver {
    fn resolve(&self, name: Name) -> Resolving {
        Box::pin(async move {
            let host = name.as_str().to_owned();
            let resolved: Vec<SocketAddr> = lookup_host((host.as_str(), 0))
                .await
                .map_err(|err| -> Box<dyn std::error::Error + Send + Sync> { Box::new(err) })?
                .collect();
            let own = OwnAddresses::detect();
            let refused = resolved
                .iter()
                .any(|a| !allowed_with_local_approval(a.ip(), &own));
            if resolved.is_empty() || refused {
                return Err("blocked address refused".into());
            }
            Ok(Box::new(resolved.into_iter()) as Addrs)
        })
    }
}

/// Every `/32 host LOCAL` entry in a Linux `fib_trie`: the host's own addresses.
fn local_ipv4s(path: &str) -> Vec<Ipv4Addr> {
    std::fs::read_to_string(path)
        .map(|text| parse_fib_trie(&text))
        .unwrap_or_default()
}

fn parse_fib_trie(text: &str) -> Vec<Ipv4Addr> {
    let mut last: Option<Ipv4Addr> = None;
    let mut found = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if let Some(addr) = line.strip_prefix("|-- ") {
            last = addr.parse().ok();
        } else if line.starts_with("/32 host LOCAL")
            && let Some(addr) = last
        {
            found.push(addr);
        }
    }
    found
}

fn default_gateway(path: &str) -> Option<Ipv4Addr> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| parse_default_gateway(&text))
}

fn parse_default_gateway(text: &str) -> Option<Ipv4Addr> {
    text.lines().skip(1).find_map(|line| {
        let mut cols = line.split_whitespace();
        let (_iface, destination, gateway) = (cols.next()?, cols.next()?, cols.next()?);
        if destination != "00000000" {
            return None;
        }
        let raw = u32::from_str_radix(gateway, 16).ok()?;
        Some(Ipv4Addr::from(raw.to_le_bytes()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    fn own() -> OwnAddresses {
        OwnAddresses::new([ip("192.168.1.2"), ip("172.17.0.2")])
    }

    #[test]
    fn local_approval_admits_private_lan_addresses() {
        for text in [
            "192.168.1.10",
            "10.0.0.5",
            "172.20.1.1",
            "fd12::5",
            "::ffff:10.0.0.5",
        ] {
            assert!(allowed_with_local_approval(ip(text), &own()), "{text}");
        }
    }

    #[test]
    fn local_approval_never_admits_loopback_link_local_or_metadata() {
        for text in [
            "127.0.0.1",
            "::1",
            "169.254.169.254",
            "169.254.1.1",
            "fe80::1",
            "0.0.0.0",
            "100.64.0.1",
            "::ffff:127.0.0.1",
        ] {
            assert!(!allowed_with_local_approval(ip(text), &own()), "{text}");
        }
    }

    #[test]
    fn local_approval_refuses_the_servers_own_addresses_and_docker_bridge() {
        for text in [
            "192.168.1.2",
            "172.17.0.2",
            "172.17.0.1",
            "172.17.5.9",
            "::ffff:192.168.1.2",
        ] {
            assert!(!allowed_with_local_approval(ip(text), &own()), "{text}");
        }
        assert!(allowed_with_local_approval(ip("192.168.1.3"), &own()));
    }

    #[test]
    fn local_approval_still_admits_public_addresses() {
        assert!(allowed_with_local_approval(ip("1.1.1.1"), &own()));
    }

    #[test]
    fn the_fib_trie_yields_only_local_host_entries() {
        let trie = "Main:\n  +-- 0.0.0.0/0 3 0 5\n     |-- 0.0.0.0\n        /0 universe UNICAST\n     +-- 10.0.0.0/24 2 0 2\n        |-- 10.0.0.0\n           /32 link BROADCAST\n           /24 link UNICAST\n        |-- 10.0.0.5\n           /32 host LOCAL\n";
        assert_eq!(parse_fib_trie(trie), vec![Ipv4Addr::new(10, 0, 0, 5)]);
    }

    #[test]
    fn the_default_route_yields_its_gateway() {
        let route = "Iface\tDestination\tGateway\tFlags\neth0\t00000000\t010011AC\t0003\neth0\t0000FEA9\t00000000\t0001\n";
        assert_eq!(
            parse_default_gateway(route),
            Some(Ipv4Addr::new(172, 17, 0, 1))
        );
    }

    #[tokio::test]
    async fn the_lan_resolver_refuses_a_name_that_resolves_to_loopback() {
        let refused = LanGuardResolver.resolve("localhost".parse().unwrap()).await;
        assert!(refused.is_err());
    }
}
