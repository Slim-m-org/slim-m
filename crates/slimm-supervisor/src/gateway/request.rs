// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The pure half of the egress gateway: reading a proxy request head and judging its target.

use std::net::IpAddr;

use crate::net::{Cidr, HostPort, approved_address_allowed, server_address_allowed, unmapped};

/// The gateway's whole configuration, from its environment.
#[derive(Debug, Clone, PartialEq)]
pub struct GatewayConfig {
    pub allow: Vec<HostPort>,
    pub server: HostPort,
    pub egress_private: bool,
    pub deny: Vec<Cidr>,
    pub clients: Vec<Cidr>,
    pub port: u16,
}

impl GatewayConfig {
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Result<Self, String> {
        let list = |key: &str| get(key).unwrap_or_default();
        let entries = |raw: String| -> Vec<String> {
            raw.split(',')
                .map(str::trim)
                .filter(|e| !e.is_empty())
                .map(str::to_owned)
                .collect()
        };
        let allow = entries(list("SLIMM_GATEWAY_ALLOW"))
            .iter()
            .map(|e| HostPort::parse(e).ok_or_else(|| format!("bad allow entry {e:?}")))
            .collect::<Result<_, _>>()?;
        let cidrs = |key: &str| -> Result<Vec<Cidr>, String> {
            entries(list(key))
                .iter()
                .map(|e| Cidr::parse(e).ok_or_else(|| format!("bad {key} entry {e:?}")))
                .collect()
        };
        let server = HostPort::parse(&list("SLIMM_GATEWAY_SERVER"))
            .ok_or("SLIMM_GATEWAY_SERVER must be host:port")?;
        let clients = cidrs("SLIMM_GATEWAY_CLIENTS")?;
        if clients.is_empty() {
            return Err("SLIMM_GATEWAY_CLIENTS names no subnet".into());
        }
        Ok(Self {
            allow,
            server,
            egress_private: list("SLIMM_GATEWAY_PRIVATE") == "1",
            deny: cidrs("SLIMM_GATEWAY_DENY")?,
            clients,
            port: list("SLIMM_GATEWAY_PORT")
                .parse()
                .unwrap_or(crate::sandbox::GATEWAY_PORT),
        })
    }

    pub fn client_allowed(&self, peer: IpAddr) -> bool {
        self.clients.iter().any(|c| c.contains(unmapped(peer)))
    }

    /// Whether the target is the server's API or an approved pair; anything else is refused.
    pub fn classify(&self, target: &HostPort) -> Option<Kind> {
        if *target == self.server {
            Some(Kind::Server)
        } else if self.allow.contains(target) {
            Some(Kind::Approved)
        } else {
            None
        }
    }

    /// Fails the whole name closed if any resolved address is refused, so a name with one
    /// public and one internal address cannot reach the internal one.
    pub fn check_addresses(&self, kind: Kind, addresses: &[IpAddr]) -> Result<(), IpAddr> {
        for &ip in addresses {
            let ok = match kind {
                Kind::Server => server_address_allowed(ip),
                Kind::Approved => approved_address_allowed(ip, self.egress_private, &self.deny),
            };
            if !ok {
                return Err(ip);
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Server,
    Approved,
}

/// A parsed request head: where it goes and, for plain HTTP, the head to send upstream.
#[derive(Debug, PartialEq, Eq)]
pub struct Head {
    pub target: HostPort,
    pub connect: bool,
    pub upstream: Origin,
}

/// A request head rebuilt in origin form, and whether it asks to upgrade the connection.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Origin {
    pub head: Vec<u8>,
    pub upgrade: bool,
}

/// `CONNECT host:port` tunnels; `METHOD http://host[:port]/path` forwards in origin form.
pub fn parse_head(head: &[u8]) -> Result<Head, &'static str> {
    let (method, target, version, headers) = request_line(head)?;
    if method == "CONNECT" {
        let target = HostPort::parse(target).ok_or("CONNECT needs host:port")?;
        return Ok(Head {
            target,
            connect: true,
            upstream: Origin::default(),
        });
    }
    let rest = target
        .strip_prefix("http://")
        .ok_or("only http:// URLs and CONNECT are proxied")?;
    let (authority, path) = rest
        .find('/')
        .map_or((rest, "/"), |i| (&rest[..i], &rest[i..]));
    if authority.contains('@') {
        return Err("credentials in the URL are refused");
    }
    let target = HostPort::parse(authority)
        .or_else(|| HostPort::parse(&format!("{authority}:80")))
        .ok_or("bad host in the URL")?;
    Ok(Head {
        target,
        connect: false,
        upstream: origin(method, path, version, &headers),
    })
}

/// The first request inside a CONNECT tunnel to the server, which is plain HTTP in origin form.
pub fn parse_tunnelled_head(head: &[u8]) -> Result<Origin, &'static str> {
    let (method, path, version, headers) = request_line(head)?;
    if method == "CONNECT" || !path.starts_with('/') {
        return Err("a tunnel to the server carries one origin-form HTTP request");
    }
    Ok(origin(method, path, version, &headers))
}

fn request_line(head: &[u8]) -> Result<(&str, &str, &str, Vec<&str>), &'static str> {
    let text = std::str::from_utf8(head).map_err(|_| "the request head is not UTF-8")?;
    reject_smuggling(text)?;
    let mut lines = text.split("\r\n");
    let request_line = lines.next().ok_or("empty request")?;
    let mut parts = request_line.split(' ');
    match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some(m), Some(t), Some(v), None) if matches!(v, "HTTP/1.0" | "HTTP/1.1") => {
            Ok((m, t, v, lines.collect()))
        }
        _ => Err("malformed request line"),
    }
}

/// Refuses framing a line-splitting proxy and the upstream could read differently.
fn reject_smuggling(text: &str) -> Result<(), &'static str> {
    let bytes = text.as_bytes();
    for (i, &b) in bytes.iter().enumerate() {
        let paired = match b {
            b'\r' => bytes.get(i + 1) == Some(&b'\n'),
            b'\n' => i > 0 && bytes[i - 1] == b'\r',
            _ => true,
        };
        if !paired || b == 0 {
            return Err("malformed line ending or control character in the request head");
        }
    }
    if text
        .split("\r\n")
        .skip(1)
        .any(|l| l.starts_with([' ', '\t']))
    {
        return Err("folded header lines are refused");
    }
    Ok(())
}

/// Headers a connector could claim another address with, and hop-by-hop ones the gateway sets.
fn dropped(name: &str) -> bool {
    name.starts_with("proxy-")
        || name.starts_with("x-forwarded-")
        || matches!(
            name,
            "forwarded" | "x-real-ip" | "connection" | "keep-alive"
        )
}

/// One request per connection: `Connection: close` unless it is an upgrade, so no later
/// request on the stream can skip this filter.
fn origin(method: &str, path: &str, version: &str, headers: &[&str]) -> Origin {
    let mut out = format!("{method} {path} {version}\r\n");
    let mut upgrade = false;
    for line in headers.iter().filter(|l| !l.is_empty()) {
        let (name, value) = line.split_once(':').unwrap_or((line, ""));
        let name = name.trim().to_ascii_lowercase();
        if dropped(&name) {
            continue;
        }
        upgrade |= name == "upgrade" && !value.trim().is_empty();
        out.push_str(line);
        out.push_str("\r\n");
    }
    out.push_str(if upgrade {
        "Connection: Upgrade\r\n\r\n"
    } else {
        "Connection: close\r\n\r\n"
    });
    Origin {
        head: out.into_bytes(),
        upgrade,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> GatewayConfig {
        GatewayConfig {
            allow: vec![
                HostPort::new("api.example.com", 443),
                HostPort::new("nas.lan", 8096),
            ],
            server: HostPort::new("server", 8080),
            egress_private: false,
            deny: vec![Cidr::parse("172.17.0.0/16").unwrap()],
            clients: vec![Cidr::parse("172.30.0.0/16").unwrap()],
            port: 3128,
        }
    }

    fn ip(t: &str) -> IpAddr {
        t.parse().unwrap()
    }

    #[test]
    fn only_the_server_and_approved_pairs_are_targets() {
        let c = config();
        assert_eq!(
            c.classify(&HostPort::new("server", 8080)),
            Some(Kind::Server)
        );
        assert_eq!(
            c.classify(&HostPort::new("api.example.com", 443)),
            Some(Kind::Approved)
        );
        assert_eq!(c.classify(&HostPort::new("api.example.com", 80)), None);
        assert_eq!(c.classify(&HostPort::new("server", 22)), None);
        assert_eq!(c.classify(&HostPort::new("evil.com", 443)), None);
    }

    #[test]
    fn a_name_that_resolves_inside_is_refused_whole() {
        let c = config();
        assert!(
            c.check_addresses(Kind::Approved, &[ip("93.184.215.14")])
                .is_ok()
        );
        assert_eq!(
            c.check_addresses(Kind::Approved, &[ip("93.184.215.14"), ip("10.0.0.5")]),
            Err(ip("10.0.0.5"))
        );
        assert!(
            c.check_addresses(Kind::Approved, &[ip("172.17.0.1")])
                .is_err()
        );
        assert!(c.check_addresses(Kind::Server, &[ip("172.17.0.4")]).is_ok());
        assert!(c.check_addresses(Kind::Server, &[ip("127.0.0.1")]).is_err());
        assert!(
            c.check_addresses(Kind::Server, &[ip("169.254.169.254")])
                .is_err()
        );
    }

    #[test]
    fn the_private_approval_still_loses_to_the_deny_list() {
        let mut c = config();
        c.egress_private = true;
        assert!(
            c.check_addresses(Kind::Approved, &[ip("192.168.1.9")])
                .is_ok()
        );
        assert!(
            c.check_addresses(Kind::Approved, &[ip("172.17.0.9")])
                .is_err()
        );
        assert!(
            c.check_addresses(Kind::Approved, &[ip("127.0.0.1")])
                .is_err()
        );
    }

    #[test]
    fn clients_come_only_from_the_connector_network() {
        let c = config();
        assert!(c.client_allowed(ip("172.30.0.2")));
        assert!(!c.client_allowed(ip("172.18.0.2")));
    }

    #[test]
    fn heads_parse_into_targets() {
        let head = parse_head(b"CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443")
            .unwrap();
        assert_eq!(head.target, HostPort::new("api.example.com", 443));
        assert!(head.connect);
        let head = parse_head(b"GET http://server:8080/connectors/me HTTP/1.1\r\nHost: server:8080\r\nProxy-Connection: keep-alive").unwrap();
        assert_eq!(head.target, HostPort::new("server", 8080));
        assert_eq!(
            head.upstream.head,
            b"GET /connectors/me HTTP/1.1\r\nHost: server:8080\r\nConnection: close\r\n\r\n"
        );
        assert_eq!(
            parse_head(b"GET http://x.com HTTP/1.1").unwrap().target,
            HostPort::new("x.com", 80)
        );
        for bad in [
            &b"GET https://x.com/ HTTP/1.1"[..],
            b"GET /local HTTP/1.1",
            b"GET http://u:p@x.com/ HTTP/1.1",
            b"CONNECT x.com HTTP/1.1",
            b"junk",
        ] {
            assert!(parse_head(bad).is_err(), "{}", String::from_utf8_lossy(bad));
        }
    }

    #[test]
    fn bare_line_feeds_folds_and_odd_versions_are_refused() {
        for bad in [
            &b"GET http://server:8080/ HTTP/1.1\nX-Forwarded-For: 1.2.3.4\r\nHost: server:8080"[..],
            b"GET http://server:8080/ HTTP/1.1\r\nHost: server:8080\nX-Forwarded-For: 1.2.3.4",
            b"GET http://server:8080/ HTTP/1.1\r\nHost: server:8080\r\nX-A: b\rX-Forwarded-For: 1",
            b"GET http://server:8080/ HTTP/1.1\r\nHost: server:8080\n\nGET / HTTP/1.1",
            b"GET http://server:8080/ HTTP/1.1\r\nX-A: b\r\n X-Forwarded-For: 1.2.3.4",
            b"GET http://server:8080/ HTTP/1.1\r\nX-A: b\r\n\tmore",
            b"GET http://server:8080/ HTTP/1.1\r\nX-A: b\0c",
            b"GET http://server:8080/ HTTP/1.1x",
            b"GET http://server:8080/ HTTP/1.9",
        ] {
            assert!(parse_head(bad).is_err(), "{}", String::from_utf8_lossy(bad));
            assert!(parse_tunnelled_head(bad).is_err());
        }
        assert!(parse_head(b"GET http://server:8080/ HTTP/1.0\r\nHost: s").is_ok());
    }

    /// M1: a connector must not choose the address the server keys it by.
    #[test]
    fn forwarding_headers_and_keep_alive_never_reach_upstream() {
        let head = parse_head(
            b"POST http://server:8080/auth/login HTTP/1.1\r\nHost: server:8080\r\nX-Forwarded-For: 1.2.3.4\r\nforwarded: for=1.2.3.4\r\nX-Real-IP: 1.2.3.4\r\nX-Forwarded-Proto: https\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\nContent-Length: 2",
        )
        .unwrap();
        assert_eq!(
            String::from_utf8(head.upstream.head).unwrap(),
            "POST /auth/login HTTP/1.1\r\nHost: server:8080\r\nContent-Length: 2\r\nConnection: close\r\n\r\n"
        );
        let inner = parse_tunnelled_head(
            b"GET /ws HTTP/1.1\r\nHost: server:8080\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nX-Forwarded-For: 9.9.9.9",
        )
        .unwrap();
        assert!(inner.upgrade);
        assert_eq!(
            String::from_utf8(inner.head).unwrap(),
            "GET /ws HTTP/1.1\r\nHost: server:8080\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        );
        assert!(parse_tunnelled_head(b"GET http://server:8080/ HTTP/1.1").is_err());
        assert!(parse_tunnelled_head(b"CONNECT x:1 HTTP/1.1").is_err());
    }

    #[test]
    fn config_reads_from_the_environment() {
        let env = |k: &str| match k {
            "SLIMM_GATEWAY_ALLOW" => Some("api.example.com:443,[2001:db8::1]:443".into()),
            "SLIMM_GATEWAY_SERVER" => Some("server:8080".into()),
            "SLIMM_GATEWAY_PRIVATE" => Some("1".into()),
            "SLIMM_GATEWAY_CLIENTS" => Some("172.30.0.0/16".into()),
            _ => None,
        };
        let c = GatewayConfig::from_lookup(env).unwrap();
        assert_eq!(c.allow.len(), 2);
        assert!(c.egress_private);
        assert!(GatewayConfig::from_lookup(|_| None).is_err());
    }
}
