// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The shared address-range guard behind every outbound fetch this server
//! makes to a host it does not control the meaning of: link unfurling
//! (`http::link_preview::ssrf`) and the Dock's marketplace fetch
//! (`http::dock::ssrf`). See decision 0019.
//!
//! [`is_blocked`] is the pure range check; [`GuardResolver`] is the reqwest
//! DNS resolver that enforces it on the exact addresses a connector uses,
//! rejecting the whole name if *any* resolved address is blocked so a
//! hostname whose first address is public and second is loopback cannot let
//! reqwest fall through to the internal one.
//!
//! A caller that also needs to reject a numeric IP literal before this
//! resolver ever runs (a literal host is parsed by the `url` crate directly,
//! so reqwest never calls a resolver for it) does that itself with
//! [`is_blocked`], the same way `http::link_preview::ssrf::validate` does.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use tokio::net::lookup_host;

/// The reqwest DNS resolver that fails a whole request closed if any address
/// the name resolves to is blocked. `allow_private` lets a test reach the
/// loopback a fake upstream binds to; every production path passes `false`.
pub struct GuardResolver {
    pub allow_private: bool,
}

impl Resolve for GuardResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let allow_private = self.allow_private;
        Box::pin(async move {
            let host = name.as_str().to_owned();
            let resolved: Vec<SocketAddr> = lookup_host((host.as_str(), 0))
                .await
                .map_err(|err| -> Box<dyn std::error::Error + Send + Sync> { Box::new(err) })?
                .collect();
            let blocked = !allow_private && resolved.iter().any(|a| is_blocked(a.ip()));
            if resolved.is_empty() || blocked {
                return Err("blocked address refused".into());
            }
            Ok(Box::new(resolved.into_iter()) as Addrs)
        })
    }
}

/// Whether [ip] falls in any range this server must never dial: loopback,
/// private, link-local (including the `169.254.169.254` cloud metadata
/// address), CGNAT, benchmarking, documentation/test, multicast, and reserved
/// space, across IPv4 and IPv6. Mapped and translated IPv6 forms are unpacked
/// to their embedded IPv4 and re-checked, since an attacker can wear an
/// internal v4 address inside a v6 one.
pub fn is_blocked(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_blocked_v4(v4),
        IpAddr::V6(v6) => {
            if let Some(v4) = embedded_v4(v6) {
                return is_blocked_v4(v4);
            }
            is_blocked_v6(v6)
        }
    }
}

/// The IPv4 hiding inside an IPv4-mapped (`::ffff:0:0/96`), 6to4
/// (`2002::/16`), or NAT64 (`64:ff9b::/96`) IPv6 address, if any - each is
/// really a v4 destination and must be judged as one.
fn embedded_v4(v6: Ipv6Addr) -> Option<Ipv4Addr> {
    if let Some(mapped) = v6.to_ipv4_mapped() {
        return Some(mapped);
    }
    let s = v6.segments();
    if s[0] == 0x2002 {
        return Some(Ipv4Addr::from(((s[1] as u32) << 16) | s[2] as u32));
    }
    if s[0] == 0x0064 && s[1] == 0xff9b && s[2..6].iter().all(|&x| x == 0) {
        return Some(Ipv4Addr::from(((s[6] as u32) << 16) | s[7] as u32));
    }
    None
}

fn is_blocked_v4(ip: Ipv4Addr) -> bool {
    // (network base, prefix length) for every reserved/internal range.
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
        let mask = if len == 0 { 0 } else { u32::MAX << (32 - len) };
        (n & mask) == (u32::from(base) & mask)
    })
}

fn is_blocked_v6(ip: Ipv6Addr) -> bool {
    if ip.is_loopback() || ip.is_unspecified() || ip.is_multicast() {
        return true;
    }
    let s = ip.segments();
    // fc00::/7 unique-local.
    if (s[0] & 0xfe00) == 0xfc00 {
        return true;
    }
    // fe80::/10 link-local.
    if (s[0] & 0xffc0) == 0xfe80 {
        return true;
    }
    // 2001:db8::/32 documentation.
    if s[0] == 0x2001 && s[1] == 0x0db8 {
        return true;
    }
    false
}

/// A response body ran past its cap or could not be read to the end.
#[derive(Debug)]
pub struct ReadCappedError;

/// Reads at most `cap` bytes from `response`, stopping the moment the body
/// runs over rather than buffering an unbounded one.
pub async fn read_capped(
    mut response: reqwest::Response,
    cap: usize,
) -> Result<Vec<u8>, ReadCappedError> {
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| ReadCappedError)? {
        if body.len() + chunk.len() > cap {
            return Err(ReadCappedError);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn response_of(body: &'static [u8]) -> reqwest::Response {
        let app = axum::Router::new().route("/", axum::routing::get(move || async move { body }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await });
        reqwest::get(format!("http://{addr}/")).await.unwrap()
    }

    #[tokio::test]
    async fn read_capped_refuses_a_body_over_the_cap() {
        let body = read_capped(response_of(&[7; 100]).await, 99).await;
        assert!(body.is_err());
    }

    #[tokio::test]
    async fn read_capped_returns_a_body_at_the_cap() {
        let body = read_capped(response_of(&[7; 100]).await, 100)
            .await
            .unwrap();
        assert_eq!(body, vec![7; 100]);
    }

    fn blocked(ip: &str) -> bool {
        is_blocked(ip.parse().unwrap())
    }

    #[test]
    fn blocks_the_documented_internal_ranges() {
        for ip in [
            "127.0.0.1",
            "10.1.2.3",
            "172.16.5.5",
            "192.168.1.1",
            "169.254.169.254",
            "100.64.0.1",
            "198.18.0.1",
            "0.0.0.0",
            "224.0.0.1",
            "::1",
            "fc00::1",
            "fe80::1",
            "2001:db8::1",
        ] {
            assert!(blocked(ip), "{ip} should be blocked");
        }
    }

    #[test]
    fn allows_ordinary_public_addresses() {
        for ip in ["1.1.1.1", "8.8.8.8", "140.82.113.3", "2606:4700:4700::1111"] {
            assert!(!blocked(ip), "{ip} should be allowed");
        }
    }

    #[test]
    fn unpacks_mapped_and_translated_v6_to_v4() {
        // ::ffff:127.0.0.1 (IPv4-mapped), 2002:7f00:1:: (6to4), 64:ff9b::7f00:1 (NAT64).
        assert!(blocked("::ffff:127.0.0.1"));
        assert!(blocked("2002:7f00:0001::"));
        assert!(blocked("64:ff9b::7f00:0001"));
    }
}
