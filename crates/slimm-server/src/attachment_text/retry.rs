// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bounded retry for extraction that failed for a reason that may pass.
//!
//! In memory on purpose: a restart is a fine moment to try again, and the
//! attempt cap is what stops a broken file from looping.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub const MAX_ATTEMPTS: u32 = 3;

pub struct Retries {
    backoff: Duration,
    seen: Mutex<HashMap<Vec<u8>, (u32, Instant)>>,
}

/// What to do with a file whose attempt just failed.
#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    TryLater,
    GiveUp,
}

impl Retries {
    pub fn new(backoff: Duration) -> Self {
        Self {
            backoff,
            seen: Mutex::new(HashMap::new()),
        }
    }

    pub fn is_waiting(&self, sha256: &[u8]) -> bool {
        let seen = self
            .seen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        seen.get(sha256)
            .is_some_and(|(_, next)| *next > Instant::now())
    }

    pub fn failed(&self, sha256: &[u8]) -> Verdict {
        let mut seen = self
            .seen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let attempts = seen.get(sha256).map_or(0, |(n, _)| *n) + 1;
        if attempts >= MAX_ATTEMPTS {
            seen.remove(sha256);
            return Verdict::GiveUp;
        }
        seen.insert(
            sha256.to_vec(),
            (attempts, Instant::now() + self.backoff * attempts),
        );
        Verdict::TryLater
    }

    pub fn settled(&self, sha256: &[u8]) {
        self.seen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(sha256);
    }
}
