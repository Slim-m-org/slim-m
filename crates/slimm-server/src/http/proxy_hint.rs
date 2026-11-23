// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A one-time warning when `SLIMM_TRUST_PROXY_HOPS` disagrees with the traffic.
//!
//! Every per-address limit, the login throttle included, keys on the address this
//! setting selects. Too low and every caller shares the proxy's key; too high and
//! the key is whatever the client wrote. Neither is visible to the operator
//! otherwise, so the first request that shows it says so once.

use std::sync::atomic::{AtomicBool, Ordering};

use axum::http::request::Parts;

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub(super) enum Mismatch {
    /// A proxy is forwarding but no hops are trusted: callers share the proxy's address.
    ProxyNotTrusted,
    /// Fewer forwarded entries than trusted hops: callers fall back to the peer address.
    TooFewEntries,
    /// The header is there but its sender is not a trusted proxy, so it is ignored.
    PeerNotTrusted,
}

/// What the traffic shows about the setting; `peer_trusted` is `None` when the peer is unknown.
pub(super) fn mismatch(
    forwarded_entries: usize,
    trusted_hops: usize,
    peer_trusted: Option<bool>,
) -> Option<Mismatch> {
    match (trusted_hops, forwarded_entries) {
        (0, entries) if entries > 0 => Some(Mismatch::ProxyNotTrusted),
        (hops, entries) if hops > 0 && entries > 0 && peer_trusted == Some(false) => {
            Some(Mismatch::PeerNotTrusted)
        }
        (hops, entries) if hops > 0 && entries < hops => Some(Mismatch::TooFewEntries),
        _ => None,
    }
}

static WARNED_NOT_TRUSTED: AtomicBool = AtomicBool::new(false);
static WARNED_TOO_FEW: AtomicBool = AtomicBool::new(false);
static WARNED_PEER: AtomicBool = AtomicBool::new(false);

/// Logs the first request whose forwarding header contradicts the configured hop count.
pub(super) fn observe(parts: &Parts, trusted_hops: usize, peer: Option<(std::net::IpAddr, bool)>) {
    let entries = parts
        .headers
        .get("x-forwarded-for")
        .and_then(|value| value.to_str().ok())
        .map_or(0, |header| {
            header.split(',').filter(|e| !e.trim().is_empty()).count()
        });
    let Some(found) = mismatch(entries, trusted_hops, peer.map(|(_, trusted)| trusted)) else {
        return;
    };
    let (flag, advice) = match found {
        Mismatch::ProxyNotTrusted => (
            &WARNED_NOT_TRUSTED,
            "requests carry X-Forwarded-For but SLIMM_TRUST_PROXY_HOPS is 0, so every caller behind the proxy shares one rate-limit and sign-in throttle key; set it to the number of proxies in front of the server",
        ),
        Mismatch::TooFewEntries => (
            &WARNED_TOO_FEW,
            "a request carried fewer X-Forwarded-For entries than SLIMM_TRUST_PROXY_HOPS, so it was keyed by its TCP peer; check the setting against the proxy chain",
        ),
        Mismatch::PeerNotTrusted => (
            &WARNED_PEER,
            "requests carry X-Forwarded-For but their sender is not in SLIMM_TRUSTED_PROXIES, so the header is ignored and every caller behind that proxy shares one rate-limit and sign-in throttle key; add the proxy's address (peer) to SLIMM_TRUSTED_PROXIES",
        ),
    };
    if !flag.swap(true, Ordering::Relaxed) {
        let peer = peer.map(|(ip, _)| ip.to_string());
        tracing::warn!(trusted_hops, forwarded_entries = entries, ?peer, "{advice}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_forwarding_proxy_with_no_trusted_hops_is_flagged() {
        assert_eq!(mismatch(1, 0, None), Some(Mismatch::ProxyNotTrusted));
        assert_eq!(mismatch(0, 0, None), None);
    }

    #[test]
    fn a_header_shorter_than_the_trusted_hops_is_flagged() {
        assert_eq!(mismatch(0, 1, None), Some(Mismatch::TooFewEntries));
        assert_eq!(mismatch(1, 2, Some(true)), Some(Mismatch::TooFewEntries));
        assert_eq!(mismatch(2, 2, Some(true)), None);
        assert_eq!(mismatch(5, 2, Some(true)), None);
    }

    #[test]
    fn a_header_from_a_peer_outside_the_trusted_proxies_is_flagged() {
        assert_eq!(mismatch(1, 1, Some(false)), Some(Mismatch::PeerNotTrusted));
        assert_eq!(mismatch(1, 1, Some(true)), None);
        assert_eq!(mismatch(1, 1, None), None);
        assert_eq!(mismatch(0, 1, Some(false)), Some(Mismatch::TooFewEntries));
    }
}
