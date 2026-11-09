// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reading a bucket without spending from it, for a class that charges failures and gates attempts.

use std::time::Instant;

use super::{Class, RateLimiter};

impl RateLimiter {
    /// Whether `key` holds less than one token in `class` right now. Spends nothing and starts no
    /// bucket, so a key that has never been charged is never exhausted.
    pub fn exhausted(&self, class: Class, key: &str) -> bool {
        self.exhausted_at(class, key, Instant::now())
    }

    /// [`RateLimiter::exhausted`] with an explicit clock; see [`RateLimiter::check_at`].
    pub fn exhausted_at(&self, class: Class, key: &str, now: Instant) -> bool {
        let (_, refill) = class.budget();
        let state = match self.state.lock() {
            Ok(state) => state,
            Err(poisoned) => poisoned.into_inner(),
        };
        state
            .buckets
            .get(&(class, key.to_owned()))
            .is_some_and(|bucket| {
                let refilled = now.duration_since(bucket.last).as_secs_f64() * refill;
                bucket.tokens + refilled < 1.0
            })
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn a_key_is_exhausted_only_once_its_burst_is_spent_and_until_a_token_refills() {
        let limiter = RateLimiter::new();
        let start = Instant::now();
        let (burst, refill) = Class::HelloFailure.budget();
        for _ in 0..burst as usize {
            assert!(!limiter.exhausted_at(Class::HelloFailure, "k", start));
            assert!(limiter.check_at(Class::HelloFailure, "k", start));
        }
        assert!(limiter.exhausted_at(Class::HelloFailure, "k", start));
        assert!(
            !limiter.exhausted_at(
                Class::HelloFailure,
                "k",
                start + Duration::from_secs_f64(1.0 / refill)
            ),
            "one token's worth of time ends it"
        );
    }

    #[test]
    fn asking_spends_nothing_and_tracks_nothing() {
        let limiter = RateLimiter::new();
        let now = Instant::now();
        for _ in 0..100 {
            assert!(!limiter.exhausted_at(Class::HelloFailure, "fresh", now));
        }
        assert_eq!(limiter.tracked(), 0);
        let (burst, _) = Class::HelloFailure.budget();
        for _ in 0..burst as usize {
            assert!(limiter.check_at(Class::HelloFailure, "fresh", now));
        }
    }

    #[test]
    fn keys_are_independent() {
        let limiter = RateLimiter::new();
        let now = Instant::now();
        let (burst, _) = Class::HelloFailure.budget();
        for _ in 0..burst as usize {
            limiter.check_at(Class::HelloFailure, "noisy", now);
        }
        assert!(limiter.exhausted_at(Class::HelloFailure, "noisy", now));
        assert!(!limiter.exhausted_at(Class::HelloFailure, "quiet", now));
    }
}
