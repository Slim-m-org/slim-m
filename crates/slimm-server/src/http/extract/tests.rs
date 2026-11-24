// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Unit tests for the rate-limit codes and the caller key in `http/extract.rs`.

use super::{
    ASSET, AUTHED_READ, CANVAS, GIF, INVITE_CHECK, LINK_PREVIEW, MODULE, PASSWORD, READ, REFRESH,
    TOTP, UPLOAD, WRITE, anonymous_key, class_of, forwarded_for, limit_key,
};
use crate::ratelimit::{Class, RateLimiter};
use axum::extract::ConnectInfo;
use axum::http::Request;
use axum::http::request::Parts;
use std::net::SocketAddr;

/// Each code maps to its own class, and none share one - a swap here would
/// silently charge a route the wrong budget, which is exactly the bug the
/// old `_ => Refresh` fallback caused before this match went exhaustive.
#[test]
fn every_rate_limit_code_maps_to_its_own_class() {
    let pairs = [
        (PASSWORD, Class::Password),
        (REFRESH, Class::Refresh),
        (INVITE_CHECK, Class::InviteCheck),
        (WRITE, Class::Write),
        (READ, Class::Read),
        (UPLOAD, Class::Upload),
        (CANVAS, Class::Canvas),
        (ASSET, Class::Asset),
        (GIF, Class::Gif),
        (LINK_PREVIEW, Class::LinkPreview),
        (MODULE, Class::Module),
        (TOTP, Class::Totp),
        (AUTHED_READ, Class::AuthedRead),
        (super::DIAGNOSTIC_PING, Class::DiagnosticPing),
        (super::DIAGNOSTIC_TRANSFER, Class::DiagnosticTransfer),
        (super::WEBHOOK, Class::Webhook),
        (super::LIVEKIT_WEBHOOK, Class::LiveKitWebhook),
        (super::INTERACTION, Class::Interaction),
        (super::PRESENCE_ACTIVITY, Class::PresenceActivity),
    ];
    let mut seen = std::collections::HashSet::new();
    for (code, class) in pairs {
        assert_eq!(class_of(code), class, "code {code} maps to the wrong class");
        assert!(seen.insert(class), "two codes share {class:?}");
    }
}

/// An unrecognised code panics rather than defaulting: a new code must be
/// named here, not silently charged some other class's budget.
#[test]
fn an_unknown_code_panics_rather_than_defaulting() {
    let prior = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let result = std::panic::catch_unwind(|| class_of(200));
    std::panic::set_hook(prior);
    assert!(
        result.is_err(),
        "an undefined code must not resolve to a class"
    );
}

fn parts(xff: Option<&str>) -> Parts {
    let mut builder = Request::builder();
    if let Some(value) = xff {
        builder = builder.header("x-forwarded-for", value);
    }
    builder.body(()).unwrap().into_parts().0
}

fn from_peer(peer: &str, xff: &str) -> Parts {
    let mut parts = parts(Some(xff));
    let addr: SocketAddr = peer.parse().unwrap();
    parts.extensions.insert(ConnectInfo(addr));
    parts
}

/// A forwarded header is believed only from a peer in `SLIMM_TRUSTED_PROXIES`, so a
/// caller that reaches the server directly, a connector's gateway among them, cannot pick its key.
#[test]
fn a_forwarded_header_counts_only_from_a_trusted_proxy() {
    let limiter = RateLimiter::with_proxy_trust(
        1,
        crate::ratelimit::ProxyTrust::parse("172.16.0.0/12,!172.31.254.0/24").unwrap(),
    );
    assert_eq!(
        limit_key(&from_peer("172.18.0.5:4000", "203.0.113.7"), None, &limiter),
        "ip:203.0.113.7"
    );
    assert_eq!(
        limit_key(
            &from_peer("172.31.254.9:4000", "203.0.113.7"),
            None,
            &limiter
        ),
        "ip:172.31.254.9"
    );
    assert_eq!(
        limit_key(
            &from_peer("198.51.100.2:4000", "203.0.113.7"),
            None,
            &limiter
        ),
        "ip:198.51.100.2"
    );
    assert_eq!(
        limit_key(&parts(Some("203.0.113.7")), None, &limiter),
        "ip:unknown"
    );
}

#[test]
fn a_missing_header_selects_nothing() {
    assert_eq!(forwarded_for(&parts(None), 1), None);
}

/// The client is counted `hops` from the right, so entries a caller
/// prepends can never reach the selected slot - the whole reason the count
/// is from the right and not the left.
#[test]
fn a_prepended_entry_cannot_change_the_selected_address() {
    assert_eq!(
        forwarded_for(&parts(Some("2.2.2.2")), 1).as_deref(),
        Some("2.2.2.2")
    );
    assert_eq!(
        forwarded_for(&parts(Some("spoofed, 2.2.2.2")), 1).as_deref(),
        Some("2.2.2.2")
    );
}

#[test]
fn the_hop_count_is_taken_from_the_right() {
    // Two trusted hops over "a, b, c" is two from the right: "b".
    assert_eq!(
        forwarded_for(&parts(Some("a, b, c")), 2).as_deref(),
        Some("b")
    );
}

/// A header with fewer entries than trusted hops selects nothing rather
/// than wrapping to the leftmost, so a short forged header falls back to
/// the socket peer instead of being believed.
#[test]
fn fewer_entries_than_hops_selects_nothing() {
    assert_eq!(forwarded_for(&parts(Some("only")), 2), None);
    assert_eq!(forwarded_for(&parts(Some("only")), 0), None);
}

/// A trailing comma is dropped, not counted: without that, one trusted hop
/// over `"2.2.2.2, "` would select the empty entry and key everyone who
/// sends a trailing comma into one bucket.
#[test]
fn empty_and_whitespace_entries_are_dropped_before_counting() {
    assert_eq!(
        forwarded_for(&parts(Some("2.2.2.2, ")), 1).as_deref(),
        Some("2.2.2.2")
    );
    assert_eq!(
        forwarded_for(&parts(Some("a,, b")), 1).as_deref(),
        Some("b")
    );
}

#[test]
fn an_ipv6_caller_is_keyed_by_its_slash_64_and_ipv4_by_its_address() {
    let key = |s: &str| anonymous_key(s.parse().unwrap());
    assert_eq!(key("2001:db8:1:2:aaaa::1"), "ip:2001:db8:1:2::/64");
    assert_eq!(
        key("2001:db8:1:2:ffff:ffff:ffff:ffff"),
        "ip:2001:db8:1:2::/64"
    );
    assert_ne!(key("2001:db8:1:3::1"), key("2001:db8:1:2::1"));
    assert_eq!(key("192.0.2.7"), "ip:192.0.2.7");
    assert_eq!(key("::ffff:192.0.2.7"), "ip:192.0.2.7");
}
