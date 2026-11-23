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
    pub upstream_head: Vec<u8>,
}

/// `CONNECT host:port` tunnels; `METHOD http://host[:port]/path` forwards in origin form,
/// without the proxy's own headers.
pub fn parse_head(head: &[u8]) -> Result<Head, &'static str> {
    let text = std::str::from_utf8(head).map_err(|_| "the request head is not UTF-8")?;
    let mut lines = text.split("\r\n");
    let request_line = lines.next().ok_or("empty request")?;
    let mut parts = request_line.split(' ');
    let (method, target, version) = match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some(m), Some(t), Some(v), None) if v.starts_with("HTTP/1.") => (m, t, v),
        _ => return Err("malformed request line"),
    };
    if method == "CONNECT" {
        let target = HostPort::parse(target).ok_or("CONNECT needs host:port")?;
        return Ok(Head {
            target,
            connect: true,
            upstream_head: Vec::new(),
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
    let mut upstream = format!("{method} {path} {version}\r\n");
    for line in lines {
        let name = line
            .split(':')
            .next()
            .unwrap_or_default()
            .to_ascii_lowercase();
        if !name.starts_with("proxy-") {
            upstream.push_str(line);
            upstream.push_str("\r\n");
        }
    }
    let upstream = upstream.trim_end_matches("\r\n").to_owned() + "\r\n\r\n";
    Ok(Head {
        target,
        connect: false,
        upstream_head: upstream.into_bytes(),
    })
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
            head.upstream_head,
            b"GET /connectors/me HTTP/1.1\r\nHost: server:8080\r\n\r\n"
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
