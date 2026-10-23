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
}

pub(super) fn mismatch(forwarded_entries: usize, trusted_hops: usize) -> Option<Mismatch> {
    match (trusted_hops, forwarded_entries) {
        (0, entries) if entries > 0 => Some(Mismatch::ProxyNotTrusted),
        (hops, entries) if hops > 0 && entries < hops => Some(Mismatch::TooFewEntries),
        _ => None,
    }
}

static WARNED_NOT_TRUSTED: AtomicBool = AtomicBool::new(false);
static WARNED_TOO_FEW: AtomicBool = AtomicBool::new(false);

/// Logs the first request whose forwarding header contradicts the configured hop count.
pub(super) fn observe(parts: &Parts, trusted_hops: usize) {
    let entries = parts
        .headers
        .get("x-forwarded-for")
        .and_then(|value| value.to_str().ok())
        .map_or(0, |header| {
            header.split(',').filter(|e| !e.trim().is_empty()).count()
        });
    let Some(found) = mismatch(entries, trusted_hops) else {
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
    };
    if !flag.swap(true, Ordering::Relaxed) {
        tracing::warn!(trusted_hops, forwarded_entries = entries, "{advice}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_forwarding_proxy_with_no_trusted_hops_is_flagged() {
        assert_eq!(mismatch(1, 0), Some(Mismatch::ProxyNotTrusted));
        assert_eq!(mismatch(0, 0), None);
    }

    #[test]
    fn a_header_shorter_than_the_trusted_hops_is_flagged() {
        assert_eq!(mismatch(0, 1), Some(Mismatch::TooFewEntries));
        assert_eq!(mismatch(1, 2), Some(Mismatch::TooFewEntries));
        assert_eq!(mismatch(2, 2), None);
        assert_eq!(mismatch(5, 2), None);
    }
}
