// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The IPv6 half of what counts as the server itself: the addresses it holds, its default
//! gateway and the networks of its docker bridges, read from `/proc/net/if_inet6` and
//! `/proc/net/ipv6_route`.

use std::net::{IpAddr, Ipv6Addr};

use super::{Cidr, is_docker_interface};

struct Held {
    address: Ipv6Addr,
    prefix: u8,
    interface: String,
}

struct Route {
    destination: Ipv6Addr,
    prefix: u8,
    next_hop: Ipv6Addr,
    interface: String,
}

/// Every address the host holds, its default gateway and each docker bridge's whole network.
pub(super) fn own_ranges(if_inet6: &str, ipv6_route: &str) -> Vec<Cidr> {
    let mut ranges = Vec::new();
    for held in held_addresses(if_inet6) {
        ranges.push(Cidr::host(IpAddr::V6(held.address)));
        if is_docker_interface(&held.interface) {
            ranges.push(network(held.address, held.prefix));
        }
    }
    for route in routes(ipv6_route) {
        let direct = route.next_hop.is_unspecified();
        if route.prefix == 0 && !direct {
            ranges.push(Cidr::host(IpAddr::V6(route.next_hop)));
        } else if direct && route.prefix > 0 && is_docker_interface(&route.interface) {
            ranges.push(network(route.destination, route.prefix));
        }
    }
    ranges
}

fn network(address: Ipv6Addr, prefix: u8) -> Cidr {
    Cidr {
        network: IpAddr::V6(address),
        prefix,
    }
}

fn hex_address(text: &str) -> Option<Ipv6Addr> {
    if text.len() != 32 {
        return None;
    }
    u128::from_str_radix(text, 16).ok().map(Ipv6Addr::from)
}

/// A prefix length written in hex, which a range cannot be built from when it is over 128.
fn hex_prefix(text: &str) -> Option<u8> {
    u8::from_str_radix(text, 16)
        .ok()
        .filter(|prefix| *prefix <= 128)
}

/// `address ifindex prefix scope flags interface`: the address is 32 hex digits and the
/// prefix length is hex.
fn held_addresses(text: &str) -> Vec<Held> {
    text.lines()
        .filter_map(|line| {
            let mut cols = line.split_whitespace();
            let address = hex_address(cols.next()?)?;
            let prefix = hex_prefix(cols.nth(1)?)?;
            let interface = cols.nth(2)?.to_owned();
            Some(Held {
                address,
                prefix,
                interface,
            })
        })
        .collect()
}

/// `destination prefix source source_prefix next_hop metric refcnt use flags interface`.
fn routes(text: &str) -> Vec<Route> {
    text.lines()
        .filter_map(|line| {
            let cols: Vec<&str> = line.split_whitespace().collect();
            let [destination, prefix, _, _, next_hop, .., interface] = cols.as_slice() else {
                return None;
            };
            Some(Route {
                destination: hex_address(destination)?,
                prefix: hex_prefix(prefix)?,
                next_hop: hex_address(next_hop)?,
                interface: (*interface).to_owned(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::super::{OwnAddresses, allowed_with_local_approval};
    use super::*;

    const IF_INET6: &str = "\
00000000000000000000000000000001 01 80 10 80       lo
fd123456789a00010000000000000005 02 40 00 80     eth0
fe80000000000000021122fffe334455 02 40 20 80     eth0
fdc0ffee00000001000000000000000a 05 40 00 80 br-ab12cd
fe80000000000000021122fffe33aaaa 05 40 20 80 br-ab12cd
";

    const IPV6_ROUTE: &str = "\
fdc0ffee000000010000000000000000 40 00000000000000000000000000000000 00 00000000000000000000000000000000 00000100 00000001 00000000 00000001 br-ab12cd
fd123456789a00010000000000000000 40 00000000000000000000000000000000 00 00000000000000000000000000000000 00000100 00000001 00000000 00000001 eth0
00000000000000000000000000000000 00 00000000000000000000000000000000 00 fd123456789a00010000000000000001 00000400 00000001 00000000 00000003 eth0
fe800000000000000000000000000000 40 00000000000000000000000000000000 00 00000000000000000000000000000000 00000100 00000001 00000000 00000001 eth0
";

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    fn own() -> OwnAddresses {
        OwnAddresses::default().with_denied(own_ranges(IF_INET6, IPV6_ROUTE))
    }

    #[test]
    fn the_hosts_own_unique_local_address_is_refused() {
        assert!(!allowed_with_local_approval(
            ip("fd12:3456:789a:1::5"),
            &own()
        ));
    }

    #[test]
    fn the_default_gateway_is_refused() {
        assert!(!allowed_with_local_approval(
            ip("fd12:3456:789a:1::1"),
            &own()
        ));
    }

    #[test]
    fn a_docker_bridge_network_is_refused_whole() {
        for text in [
            "fdc0:ffee:0:1::a",
            "fdc0:ffee:0:1::2",
            "fdc0:ffee:0:1:abcd::9",
        ] {
            assert!(!allowed_with_local_approval(ip(text), &own()), "{text}");
        }
    }

    #[test]
    fn other_devices_on_the_hosts_own_lan_stay_reachable() {
        for text in ["fd12:3456:789a:1::77", "fd99::1"] {
            assert!(allowed_with_local_approval(ip(text), &own()), "{text}");
        }
    }

    #[test]
    fn nothing_is_refused_when_the_kernel_tables_cannot_be_read() {
        assert!(own_ranges("", "").is_empty());
        assert!(own_ranges("garbage\n12 34", "nonsense here\n").is_empty());
        let oversized = "fdc0ffee00000001000000000000000a 05 ff 00 80 br-ab12cd\n";
        assert!(own_ranges(oversized, "").is_empty());
    }

    #[test]
    fn a_line_of_if_inet6_yields_its_address_prefix_and_interface() {
        let held = held_addresses(IF_INET6);
        assert_eq!(held.len(), 5);
        let lan: Ipv6Addr = "fd12:3456:789a:1::5".parse().unwrap();
        assert_eq!(held[1].address, lan);
        assert_eq!((held[1].prefix, held[1].interface.as_str()), (64, "eth0"));
    }
}
