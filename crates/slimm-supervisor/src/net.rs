// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Address ranges and host names: the pure half of the egress gateway's checks.
//! The ranges mirror the server's `net_guard` (decision 0019); this crate does not link the server.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use serde::{Deserialize, Serialize};

/// A host and port the gateway may forward to.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostPort {
    pub host: String,
    pub port: u16,
}

impl HostPort {
    pub fn new(host: &str, port: u16) -> Self {
        Self {
            host: host.to_owned(),
            port,
        }
    }

    /// `http://host:port` with nothing after the port but an optional `/`.
    pub fn from_http_url(url: &str) -> Option<Self> {
        let rest = url.strip_prefix("http://")?.trim_end_matches('/');
        let (host, port) = split_host_port(rest)?;
        normalize_host(host).map(|host| Self { host, port })
    }

    /// `host:port` or `[v6]:port`.
    pub fn parse(text: &str) -> Option<Self> {
        let (host, port) = split_host_port(text)?;
        normalize_host(host).map(|host| Self { host, port })
    }
}

impl std::fmt::Display for HostPort {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.host.contains(':') {
            write!(f, "[{}]:{}", self.host, self.port)
        } else {
            write!(f, "{}:{}", self.host, self.port)
        }
    }
}

fn split_host_port(text: &str) -> Option<(&str, u16)> {
    let (host, port) = text.rsplit_once(':')?;
    let host = host
        .strip_prefix('[')
        .and_then(|h| h.strip_suffix(']'))
        .unwrap_or(host);
    let port: u16 = port.parse().ok().filter(|p| *p != 0)?;
    Some((host, port))
}

/// A lowercase DNS name of letters, digits and hyphens, or a canonical IP literal.
pub fn normalize_host(host: &str) -> Option<String> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Some(unmapped(ip).to_string());
    }
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    if ends_in_a_number(&host) {
        return None;
    }
    let label_ok = |l: &str| {
        !l.is_empty()
            && l.len() <= 63
            && !l.starts_with('-')
            && !l.ends_with('-')
            && l.chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    };
    (!host.is_empty() && host.len() <= 253 && host.split('.').all(label_ok)).then_some(host)
}

/// The WHATWG URL rule: a last label of digits or `0x` hex makes a resolver read the whole
/// name as an IPv4 address (`127.1`, `0x7f000001`), which a consent screen would hide.
pub fn ends_in_a_number(host: &str) -> bool {
    let last = host.rsplit('.').next().unwrap_or_default();
    let hex = last
        .strip_prefix("0x")
        .is_some_and(|h| h.chars().all(|c| c.is_ascii_hexdigit()));
    hex || (!last.is_empty() && last.chars().all(|c| c.is_ascii_digit()))
}

/// An address or a CIDR range, v4 or v6.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cidr {
    network: IpAddr,
    prefix: u8,
}

impl Cidr {
    pub fn host(ip: IpAddr) -> Self {
        let ip = unmapped(ip);
        Self {
            network: ip,
            prefix: if ip.is_ipv4() { 32 } else { 128 },
        }
    }

    /// `10.0.0.5` or `10.0.0.0/24`; `None` for anything else.
    pub fn parse(text: &str) -> Option<Self> {
        let (addr, prefix) = match text.split_once('/') {
            Some((addr, prefix)) => (addr, Some(prefix.parse::<u8>().ok()?)),
            None => (text, None),
        };
        let network = unmapped(addr.trim().parse().ok()?);
        let max = if network.is_ipv4() { 32 } else { 128 };
        let prefix = prefix.unwrap_or(max);
        (prefix <= max).then_some(Self { network, prefix })
    }

    pub fn contains(&self, ip: IpAddr) -> bool {
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

impl std::fmt::Display for Cidr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}/{}", self.network, self.prefix)
    }
}

/// The IPv4 inside a mapped, 6to4 or NAT64 IPv6 address, which must be judged as v4.
pub fn unmapped(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => embedded_v4(v6).map_or(ip, IpAddr::V4),
        v4 => v4,
    }
}

fn embedded_v4(v6: Ipv6Addr) -> Option<Ipv4Addr> {
    if let Some(mapped) = v6.to_ipv4_mapped() {
        return Some(mapped);
    }
    let s = v6.segments();
    if s[0] == 0x2002 {
        return Some(Ipv4Addr::from((u32::from(s[1]) << 16) | u32::from(s[2])));
    }
    if s[0] == 0x0064 && s[1] == 0xff9b && s[2..6].iter().all(|&x| x == 0) {
        return Some(Ipv4Addr::from((u32::from(s[6]) << 16) | u32::from(s[7])));
    }
    None
}

/// Never dialled, whatever is approved: loopback, unspecified, link-local (the metadata
/// address among them), multicast and broadcast.
pub fn never_allowed(ip: IpAddr) -> bool {
    match unmapped(ip) {
        IpAddr::V4(v4) => {
            v4.is_loopback()
                || v4.is_unspecified()
                || v4.is_link_local()
                || v4.is_multicast()
                || v4.is_broadcast()
                || v4.octets()[0] == 0
        }
        IpAddr::V6(v6) => {
            let s = v6.segments();
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || matches!(s[0] & 0xffc0, 0xfe80 | 0xfec0)
                || v6 == AWS_V6_METADATA
        }
    }
}

const AWS_V6_METADATA: Ipv6Addr = Ipv6Addr::new(0xfd00, 0x0ec2, 0, 0, 0, 0, 0, 0x0254);

/// The private LAN ranges the Private network approval lifts: 10/8, 172.16/12, 192.168/16 and fc00::/7.
pub fn is_lan(ip: IpAddr) -> bool {
    match unmapped(ip) {
        IpAddr::V4(v4) => {
            let [a, b, ..] = v4.octets();
            a == 10 || (a == 172 && (16..32).contains(&b)) || (a == 192 && b == 168)
        }
        IpAddr::V6(v6) => (v6.segments()[0] & 0xfe00) == 0xfc00,
    }
}

/// Every range that is not the public internet, as the server's `net_guard::is_blocked` lists them.
pub fn is_non_public(ip: IpAddr) -> bool {
    match unmapped(ip) {
        IpAddr::V4(v4) => non_public_v4(v4),
        IpAddr::V6(v6) => non_public_v6(v6),
    }
}

fn non_public_v4(ip: Ipv4Addr) -> bool {
    const BLOCKS: &[(Ipv4Addr, u32)] = &[
        (Ipv4Addr::new(0, 0, 0, 0), 8),
        (Ipv4Addr::new(10, 0, 0, 0), 8),
        (Ipv4Addr::new(100, 64, 0, 0), 10),
        (Ipv4Addr::new(127, 0, 0, 0), 8),
        (Ipv4Addr::new(169, 254, 0, 0), 16),
        (Ipv4Addr::new(172, 16, 0, 0), 12),
        (Ipv4Addr::new(192, 0, 0, 0), 24),
        (Ipv4Addr::new(192, 0, 2, 0), 24),
        (Ipv4Addr::new(192, 88, 99, 0), 24),
        (Ipv4Addr::new(192, 168, 0, 0), 16),
        (Ipv4Addr::new(198, 18, 0, 0), 15),
        (Ipv4Addr::new(198, 51, 100, 0), 24),
        (Ipv4Addr::new(203, 0, 113, 0), 24),
        (Ipv4Addr::new(224, 0, 0, 0), 4),
        (Ipv4Addr::new(240, 0, 0, 0), 4),
    ];
    let n = u32::from(ip);
    BLOCKS.iter().any(|&(base, len)| {
        let mask = u32::MAX << (32 - len);
        (n & mask) == (u32::from(base) & mask)
    })
}

fn non_public_v6(ip: Ipv6Addr) -> bool {
    if ip.is_loopback() || ip.is_unspecified() || ip.is_multicast() {
        return true;
    }
    let s = ip.segments();
    (s[0] & 0xfe00) == 0xfc00
        || matches!(s[0] & 0xffc0, 0xfe80 | 0xfec0)
        || (s[0] == 0x2001 && matches!(s[1], 0x0db8 | 0x0000))
        || (s[0] == 0x0064 && s[1] == 0xff9b && s[2] == 0x0001)
        || (s[0] == 0x0100 && s[1..4].iter().all(|&x| x == 0))
}

/// What the gateway may dial for an approved host: never the always-refused ranges or the
/// deny list; a LAN address only with the Private network approval; nothing else non-public.
pub fn approved_address_allowed(ip: IpAddr, egress_private: bool, deny: &[Cidr]) -> bool {
    if never_allowed(ip) || deny.iter().any(|c| c.contains(ip)) {
        return false;
    }
    if is_lan(ip) {
        return egress_private;
    }
    !is_non_public(ip)
}

/// The server's API address is the one private address always allowed, but never loopback or link-local.
pub fn server_address_allowed(ip: IpAddr) -> bool {
    !never_allowed(ip)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    #[test]
    fn metadata_loopback_and_link_local_are_never_allowed() {
        for text in [
            "127.0.0.1",
            "169.254.169.254",
            "0.0.0.0",
            "::1",
            "fe80::1",
            "::ffff:127.0.0.1",
            "fd00:ec2::254",
            "224.0.0.1",
            "255.255.255.255",
        ] {
            assert!(!approved_address_allowed(ip(text), true, &[]), "{text}");
            assert!(!server_address_allowed(ip(text)), "{text}");
        }
    }

    #[test]
    fn lan_needs_the_private_approval_and_loses_to_the_deny_list() {
        let lan = ip("192.168.1.20");
        assert!(!approved_address_allowed(lan, false, &[]));
        assert!(approved_address_allowed(lan, true, &[]));
        let deny = [Cidr::parse("192.168.1.0/24").unwrap()];
        assert!(!approved_address_allowed(lan, true, &deny));
        assert!(!approved_address_allowed(
            ip("::ffff:192.168.1.20"),
            true,
            &deny
        ));
    }

    #[test]
    fn public_addresses_pass_unless_denied() {
        assert!(approved_address_allowed(ip("93.184.215.14"), false, &[]));
        assert!(!approved_address_allowed(
            ip("93.184.215.14"),
            false,
            &[Cidr::parse("93.184.0.0/16").unwrap()]
        ));
        assert!(!approved_address_allowed(ip("100.64.0.1"), true, &[]));
        assert!(!approved_address_allowed(ip("2002:7f00:1::"), true, &[]));
    }

    #[test]
    fn host_names_are_normalized_and_junk_is_refused() {
        assert_eq!(
            normalize_host("API.Example.com."),
            Some("api.example.com".into())
        );
        assert_eq!(normalize_host("::ffff:10.0.0.1"), Some("10.0.0.1".into()));
        for numeric in [
            "127.1",
            "0x7f000001",
            "0xc0a80101",
            "2130706433",
            "0177.0.0.1",
            "a.0x",
            "nas.10",
        ] {
            assert_eq!(normalize_host(numeric), None, "{numeric}");
        }
        assert_eq!(
            normalize_host("1password.com"),
            Some("1password.com".into())
        );
        assert_eq!(normalize_host("10.0.0.1"), Some("10.0.0.1".into()));
        for bad in [
            "",
            "*",
            "a b",
            "-x.com",
            "x..com",
            "evil.com/path",
            "user@host",
        ] {
            assert_eq!(normalize_host(bad), None, "{bad}");
        }
    }

    #[test]
    fn host_port_parses_both_forms() {
        assert_eq!(
            HostPort::parse("[::1]:443"),
            Some(HostPort::new("::1", 443))
        );
        assert_eq!(HostPort::parse("x.com:0"), None);
        assert_eq!(
            HostPort::from_http_url("http://server:8080/"),
            Some(HostPort::new("server", 8080))
        );
        assert_eq!(HostPort::from_http_url("https://server:8080"), None);
        assert_eq!(HostPort::from_http_url("http://server:8080/api"), None);
    }
}
