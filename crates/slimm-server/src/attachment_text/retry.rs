// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Backoff for extraction that failed for a reason that may pass.
//!
//! In memory on purpose: a restart is a fine moment to try again. A file is
//! never given up on, only retried less often, so a transient outage cannot
//! leave it unsearchable for good.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const MAX_BACKOFF: Duration = Duration::from_secs(60 * 60);

pub struct Retries {
    backoff: Duration,
    seen: Mutex<HashMap<Vec<u8>, (u32, Instant)>>,
}

impl Retries {
    pub fn new(backoff: Duration) -> Self {
        Self {
            backoff,
            seen: Mutex::new(HashMap::new()),
        }
    }

    fn seen(&self) -> std::sync::MutexGuard<'_, HashMap<Vec<u8>, (u32, Instant)>> {
        self.seen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The files still inside their backoff, which the next batch query skips.
    pub fn waiting(&self) -> Vec<Vec<u8>> {
        let now = Instant::now();
        self.seen()
            .iter()
            .filter(|(_, (_, next))| *next > now)
            .map(|(sha256, _)| sha256.clone())
            .collect()
    }

    /// Doubles the wait after each failure, up to an hour.
    pub fn failed(&self, sha256: &[u8]) {
        let mut seen = self.seen();
        let attempts = seen.get(sha256).map_or(0, |(n, _)| *n).saturating_add(1);
        let doublings = (attempts - 1).min(24);
        let wait = self
            .backoff
            .saturating_mul(1u32 << doublings)
            .min(MAX_BACKOFF);
        seen.insert(sha256.to_vec(), (attempts, Instant::now() + wait));
    }

    pub fn settled(&self, sha256: &[u8]) {
        self.seen().remove(sha256);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_wait_doubles_and_is_capped_at_an_hour() {
        let retries = Retries::new(Duration::from_secs(60));
        let sha = [1u8; 32];
        let mut waits = Vec::new();
        for _ in 0..8 {
            retries.failed(&sha);
            let (_, next) = retries.seen()[&sha.to_vec()];
            waits.push(next.duration_since(Instant::now()).as_secs().div_ceil(10) * 10);
        }
        assert_eq!(waits, [60, 120, 240, 480, 960, 1920, 3600, 3600]);
    }

    #[test]
    fn a_settled_file_is_no_longer_waiting() {
        let retries = Retries::new(Duration::from_secs(60));
        retries.failed(&[2u8; 32]);
        assert_eq!(retries.waiting().len(), 1);
        retries.settled(&[2u8; 32]);
        assert!(retries.waiting().is_empty());
    }
}
