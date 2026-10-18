// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one thing a module's local network approval lifts: private LAN
//! ranges (10/8, 172.16/12, 192.168/16, fc00::/7). Loopback, link-local, the
//! cloud metadata address and everything else [`super::is_blocked`] refuses
//! stay refused, and so do the server's own addresses, its docker host, every
//! docker bridge network it can see and the operator's deny list, which are
//! private ranges too but are not "a device at home".

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

/// An address or a CIDR range, v4 or v6.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cidr {
    network: IpAddr,
    prefix: u8,
}

impl Cidr {
    fn host(ip: IpAddr) -> Self {
        let prefix = if ip.is_ipv4() { 32 } else { 128 };
        Self {
            network: ip,
            prefix,
        }
    }

    /// `10.0.0.5` or `10.0.0.0/24`; `None` for anything else.
    pub fn parse(text: &str) -> Option<Self> {
        let (addr, prefix) = match text.split_once('/') {
            Some((addr, prefix)) => (addr, Some(prefix.parse::<u8>().ok()?)),
            None => (text, None),
        };
        let network: IpAddr = unmapped(addr.trim().parse().ok()?);
        let max = if network.is_ipv4() { 32 } else { 128 };
        let prefix = prefix.unwrap_or(max);
        (prefix <= max).then_some(Self { network, prefix })
    }

    fn contains(&self, ip: IpAddr) -> bool {
        let (net, ip) = match (self.network, unmapped(ip)) {
            (IpAddr::V4(n), IpAddr::V4(i)) => (u128::from(u32::from(n)), u128::from(u32::from(i))),
            (IpAddr::V6(n), IpAddr::V6(i)) => (u128::from(n), u128::from(i)),
            _ => return false,
        };
        let bits = if self.network.is_ipv4() { 32 } else { 128 };
        let shift = bits - u32::from(self.prefix);
        shift >= 128 || (net >> shift) == (ip >> shift)
    }
}

/// `SLIMM_MODULE_LAN_DENY`: comma separated IPs or CIDRs a LAN-approved module may never dial.
fn parse_denied(raw: &str) -> Vec<Cidr> {
    raw.split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .filter_map(|entry| {
            let parsed = Cidr::parse(entry);
            if parsed.is_none() {
                tracing::warn!(
                    entry,
                    "SLIMM_MODULE_LAN_DENY entry is not an IP or CIDR; ignoring it"
                );
            }
            parsed
        })
        .collect()
}

/// The IP literal hosts of `SLIMM_DIRECT_ADDRESSES` (`host:port` entries): the docker host's own
/// LAN address, which a module must not reach through the server's container.
fn direct_hosts(raw: &str) -> Vec<IpAddr> {
    raw.split(',')
        .filter_map(|entry| {
            let host = entry.trim().rsplit_once(':')?.0.trim_matches(['[', ']']);
            host.parse().ok()
        })
        .collect()
}

/// Addresses and networks that are the server itself, its host or its container networks,
/// which a private range would otherwise admit.
#[derive(Debug, Default, Clone)]
pub struct OwnAddresses {
    denied: Vec<Cidr>,
}

impl OwnAddresses {
    pub fn new(addresses: impl IntoIterator<Item = IpAddr>) -> Self {
        let mut denied = Vec::new();
        for ip in addresses {
            denied.push(Cidr::host(unmapped(ip)));
            if let IpAddr::V4(v4) = ip
                && in_docker_range(v4)
            {
                let [a, b, ..] = v4.octets();
                denied.push(Cidr {
                    network: IpAddr::V4(Ipv4Addr::new(a, b, 0, 0)),
                    prefix: 16,
                });
            }
        }
        Self { denied }
    }

    /// Adds operator-chosen hosts and networks that stay refused.
    pub fn with_denied(mut self, extra: impl IntoIterator<Item = Cidr>) -> Self {
        self.denied.extend(extra);
        self
    }

    /// What this host answers on right now (read from the kernel on Linux), every docker
    /// bridge network the process can see, the `SLIMM_DIRECT_ADDRESSES` hosts and the
    /// `SLIMM_MODULE_LAN_DENY` list.
    pub fn detect() -> Self {
        let mut found = local_ipv4s("/proc/net/fib_trie");
        found.extend(default_gateway("/proc/net/route"));
        let direct = std::env::var("SLIMM_DIRECT_ADDRESSES").unwrap_or_default();
        let operator = std::env::var("SLIMM_MODULE_LAN_DENY").unwrap_or_default();
        let routes = std::fs::read_to_string("/proc/net/route").unwrap_or_default();
        Self::new(found.into_iter().map(IpAddr::V4))
            .with_denied(bridge_networks(&routes))
            .with_denied(direct_hosts(&direct).into_iter().map(Cidr::host))
            .with_denied(parse_denied(&operator))
    }

    fn covers(&self, ip: IpAddr) -> bool {
        self.denied.iter().any(|cidr| cidr.contains(ip))
    }
}

/// Directly connected routes that are docker networks: a `br-`/`docker` interface, or any
/// network inside docker's 172.16/12 pool.
fn bridge_networks(route_table: &str) -> Vec<Cidr> {
    route_table
        .lines()
        .skip(1)
        .filter_map(|line| {
            let mut cols = line.split_whitespace();
            let (iface, destination, gateway) = (cols.next()?, cols.next()?, cols.next()?);
            let mask = cols.nth(4)?;
            let network = Ipv4Addr::from(u32::from_str_radix(destination, 16).ok()?.swap_bytes());
            let prefix = u32::from_str_radix(mask, 16)
                .ok()?
                .swap_bytes()
                .count_ones();
            let direct = u32::from_str_radix(gateway, 16).ok()? == 0;
            let docker = iface.starts_with("br-") || iface.starts_with("docker");
            (direct && prefix > 0 && (docker || in_docker_range(network))).then_some(Cidr {
                network: IpAddr::V4(network),
                prefix: prefix as u8,
            })
        })
        .collect()
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
    fn the_docker_hosts_direct_address_and_operator_deny_list_stay_refused() {
        let own = OwnAddresses::new([ip("172.17.0.2")])
            .with_denied(
                direct_hosts("10.0.0.100:443, [fd00::7]:443, example.com:443")
                    .into_iter()
                    .map(Cidr::host),
            )
            .with_denied(parse_denied(
                "192.168.1.0/24, 10.9.9.9, nonsense, 10.1.0.0/99",
            ));
        for text in [
            "10.0.0.100",
            "fd00::7",
            "192.168.1.77",
            "10.9.9.9",
            "::ffff:10.0.0.100",
        ] {
            assert!(!allowed_with_local_approval(ip(text), &own), "{text}");
        }
        for text in ["10.0.0.101", "192.168.2.5", "10.1.0.1"] {
            assert!(allowed_with_local_approval(ip(text), &own), "{text}");
        }
    }

    #[test]
    fn every_docker_bridge_network_in_the_route_table_is_refused() {
        let route = "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n\
            eth0\t00000000\t010011AC\t0003\t0\t0\t0\t00000000\t0\t0\t0\n\
            eth0\t000011AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0\n\
            br-ab12\t0002A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n\
            eth1\t0000000A\t00000000\t0001\t0\t0\t0\t000000FF\t0\t0\t0\n\
            eth2\t000014AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0\n";
        let own = OwnAddresses::default().with_denied(bridge_networks(route));
        for text in ["172.17.0.9", "192.168.2.40", "172.20.3.4"] {
            assert!(!allowed_with_local_approval(ip(text), &own), "{text}");
        }
        assert!(allowed_with_local_approval(ip("10.5.5.5"), &own));
        assert!(allowed_with_local_approval(ip("192.168.1.5"), &own));
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
