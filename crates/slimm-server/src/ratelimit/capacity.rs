// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the limiter does when its map is full (issue 2068).
//!
//! Refusing every new key once the map held its ceiling meant one IPv6 /64
//! could mint enough addresses to lock every new caller out, signed-in
//! members included. Two things change that: a full bucket is the same as no
//! bucket, so those are dropped before anything is refused; and past the
//! ceiling only anonymous keys, the ones a caller can mint, are refused.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use super::{Bucket, Class};

/// Room left for keys a caller cannot mint (members, modules) once anonymous
/// ones have filled [`super::MAX_BUCKETS`]; still a hard bound on memory.
pub(super) const MEMBER_HEADROOM: usize = 10_000;

/// Drops idle buckets and ones that have refilled to their burst: neither
/// remembers anything a fresh bucket would not.
pub(super) fn reclaim(
    buckets: &mut HashMap<(Class, String), Bucket>,
    now: Instant,
    idle_ttl: Duration,
) {
    buckets.retain(|(class, _), bucket| {
        let elapsed = now.duration_since(bucket.last);
        let (burst, refill) = class.budget();
        elapsed < idle_ttl && bucket.tokens + elapsed.as_secs_f64() * refill < burst
    });
}

/// A key the caller chose by choosing where to connect from.
pub(super) fn is_anonymous(key: &str) -> bool {
    key.starts_with("ip:")
}

#[cfg(test)]
mod tests;
