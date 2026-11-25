// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A per-member cap on attachment downloads still streaming.
//!
//! The rate class meters how fast downloads start, not how long a slow reader
//! keeps one open, so the response body carries a slot until it ends.

use axum::body::Body;
use axum::response::Response;
use futures_util::StreamExt;

use super::error::ApiError;
use crate::ratelimit::RateLimiter;
use crate::ratelimit::streams::StreamPermit;

/// Downloads one member may have open at once; a few devices each loading a page of thumbnails stay under it.
pub(super) const MAX_OPEN_DOWNLOADS: usize = 64;

/// Seconds a refused client waits; a slot frees as soon as any open body ends.
const RETRY_AFTER_SECONDS: u64 = 2;

/// Takes a download slot for `key`, refusing with a 429 while the member holds the cap.
pub(super) fn take(limiter: &RateLimiter, key: &str) -> Result<StreamPermit, ApiError> {
    limiter
        .open_stream(key, MAX_OPEN_DOWNLOADS)
        .ok_or(ApiError::RateLimited {
            retry_after_seconds: RETRY_AFTER_SECONDS,
        })
}

/// Keeps `permit` alive until `response`'s body is finished or dropped.
pub(super) fn hold_until_sent(permit: StreamPermit, response: Response) -> Response {
    let (parts, body) = response.into_parts();
    let held = body.into_data_stream().map(move |chunk| {
        let _slot = &permit;
        chunk
    });
    Response::from_parts(parts, Body::from_stream(held))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_member_past_the_cap_is_refused_with_a_wait() {
        let limiter = RateLimiter::new();
        let held: Vec<_> = (0..MAX_OPEN_DOWNLOADS)
            .map(|_| take(&limiter, "u").ok().expect("a slot under the cap"))
            .collect();
        let refused = take(&limiter, "u").err();
        assert!(matches!(
            refused,
            Some(ApiError::RateLimited {
                retry_after_seconds: RETRY_AFTER_SECONDS
            })
        ));
        assert!(take(&limiter, "other").is_ok());
        drop(held);
        assert!(take(&limiter, "u").is_ok());
    }
}
