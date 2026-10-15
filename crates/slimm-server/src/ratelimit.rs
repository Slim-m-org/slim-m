// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! In-process rate limiting.
//!
//! Every review of the auth work flagged the same gap: the expensive endpoints
//! were reachable without any per-caller throttle, so one client could keep the
//! Argon2id permits saturated and lock everyone else out. This is that throttle.
//!
//! The model is a token bucket per (class, key). A class is a traffic kind with
//! its own budget ([`Class`]); a key is whoever the limit applies to, an IP for
//! unauthenticated traffic and a user for authenticated traffic. Buckets refill
//! continuously, so a caller who stays under the sustained rate is never
//! blocked, while a burst is capped.
//!
//! Two bounds keep the limiter itself from becoming the leak it prevents:
//! idle buckets are swept on a schedule, and the map has a ceiling past which
//! new anonymous keys are refused rather than admitted (fail closed, so
//! flooding with fresh keys cannot grow memory without bound or buy free
//! requests). See [`capacity`] for what happens at the ceiling.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

mod capacity;
mod class;
mod class_label;
pub use class::Class;

/// Most distinct keys tracked at once, across all classes.
const MAX_BUCKETS: usize = 20_000;
/// A bucket untouched for this long is swept.
const IDLE_TTL: Duration = Duration::from_secs(300);
/// How often the sweep runs, checked lazily on access.
const SWEEP_INTERVAL: Duration = Duration::from_secs(60);

#[derive(Debug)]
struct Bucket {
    tokens: f64,
    last: Instant,
}

/// How many requests a class has admitted and refused since the process
/// started, for the `/metrics` counters. Lives beside the buckets rather
/// than as its own `Mutex`, since every increment already happens under the
/// same lock a check takes anyway.
#[derive(Debug, Default, Clone, Copy)]
pub struct ClassCounts {
    pub admitted: u64,
    pub refused: u64,
}

struct State {
    buckets: HashMap<(Class, String), Bucket>,
    last_sweep: Instant,
    counts: HashMap<Class, ClassCounts>,
}

/// How many whole seconds until a refused caller's bucket holds what it asked
/// for, never less than one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RetryAfter(pub u64);

/// A cloneable handle to the shared limiter.
#[derive(Clone)]
pub struct RateLimiter {
    state: Arc<Mutex<State>>,
    trusted_hops: usize,
}

impl Default for RateLimiter {
    fn default() -> Self {
        Self::new()
    }
}

impl RateLimiter {
    pub fn new() -> Self {
        Self::with_trusted_hops(0)
    }

    /// A limiter that trusts `hops` proxies in front of it when keying an
    /// unauthenticated caller. Zero, the default, trusts none and keys on the
    /// TCP peer; see [`RateLimiter::trusted_hops`].
    pub fn with_trusted_hops(trusted_hops: usize) -> Self {
        Self {
            state: Arc::new(Mutex::new(State {
                buckets: HashMap::new(),
                last_sweep: Instant::now(),
                counts: HashMap::new(),
            })),
            trusted_hops,
        }
    }

    /// How many proxies in front of this server may be believed about who the
    /// caller is.
    ///
    /// Zero means the TCP peer is the only thing believed, which is right for a
    /// directly-exposed server and is what a forwarded header cannot be trusted
    /// for: anyone may send one. Non-zero is an operator asserting they control
    /// that many hops, which makes the address that many places from the *right*
    /// of `X-Forwarded-For` as trustworthy as the peer - a caller can prepend
    /// anything they like to that header and never reach the slot.
    ///
    /// It has to be configurable rather than inferred because nothing in a
    /// request distinguishes a proxy the operator runs from one they do not.
    pub fn trusted_hops(&self) -> usize {
        self.trusted_hops
    }

    /// Takes one token for `key` in `class`, returning false if the caller is
    /// over budget and the request should be refused.
    pub fn check(&self, class: Class, key: &str) -> bool {
        self.check_at(class, key, Instant::now())
    }

    /// [`RateLimiter::check`] with an explicit clock, so tests can advance time
    /// without sleeping.
    pub fn check_at(&self, class: Class, key: &str, now: Instant) -> bool {
        self.check_weighted_at(class, key, 1.0, now)
    }

    /// [`RateLimiter::check`], charging `cost` tokens rather than the
    /// implicit one - the mechanism [`Class::CanvasStrokePreview`] uses to
    /// meter bytes instead of requests, by passing the frame's own wire size
    /// as `cost`. A `cost` larger than the class's whole burst is always
    /// refused, rather than admitted against an under-provisioned bucket.
    pub fn check_weighted(&self, class: Class, key: &str, cost: f64) -> bool {
        self.check_weighted_at(class, key, cost, Instant::now())
    }

    /// [`RateLimiter::check_weighted`] with an explicit clock; see
    /// [`RateLimiter::check_at`].
    pub fn check_weighted_at(&self, class: Class, key: &str, cost: f64, now: Instant) -> bool {
        self.admit_at(class, key, cost, now).is_ok()
    }

    /// [`RateLimiter::check`] that says how long to wait when it refuses, so
    /// every 429 can carry a `Retry-After` computed by the same refill
    /// arithmetic that refused it.
    pub fn admit(&self, class: Class, key: &str) -> Result<(), RetryAfter> {
        self.admit_at(class, key, 1.0, Instant::now())
    }

    /// The one admission decision; [`RateLimiter::check_weighted_at`] and
    /// [`RateLimiter::admit`] both read it.
    pub fn admit_at(
        &self,
        class: Class,
        key: &str,
        cost: f64,
        now: Instant,
    ) -> Result<(), RetryAfter> {
        let (burst, refill) = class.budget();
        let wait_for = |deficit: f64| RetryAfter((deficit / refill).ceil().max(1.0) as u64);
        if cost > burst {
            return Err(wait_for(burst));
        }
        let mut state = match self.state.lock() {
            Ok(state) => state,
            // A poisoned lock means another thread panicked mid-update. Fail
            // open rather than wedging every request behind a dead limiter.
            Err(poisoned) => poisoned.into_inner(),
        };

        if now.duration_since(state.last_sweep) >= SWEEP_INTERVAL {
            state
                .buckets
                .retain(|_, bucket| now.duration_since(bucket.last) < IDLE_TTL);
            state.last_sweep = now;
        }

        let map_key = (class, key.to_owned());
        let outcome = match state.buckets.get_mut(&map_key) {
            Some(bucket) => {
                let elapsed = now.duration_since(bucket.last).as_secs_f64();
                bucket.tokens = (bucket.tokens + elapsed * refill).min(burst);
                bucket.last = now;
                if bucket.tokens >= cost {
                    bucket.tokens -= cost;
                    Ok(())
                } else {
                    Err(wait_for(cost - bucket.tokens))
                }
            }
            None => {
                if state.buckets.len() >= MAX_BUCKETS {
                    capacity::reclaim(&mut state.buckets, now, IDLE_TTL);
                }
                // Past the ceiling a fresh anonymous key is refused, so a flood cannot grow memory or buy requests.
                let len = state.buckets.len();
                let full = len >= MAX_BUCKETS && capacity::is_anonymous(key);
                if full || len >= MAX_BUCKETS + capacity::MEMBER_HEADROOM {
                    Err(wait_for(cost))
                } else {
                    state.buckets.insert(
                        map_key,
                        Bucket {
                            tokens: burst - cost,
                            last: now,
                        },
                    );
                    Ok(())
                }
            }
        };
        let entry = state.counts.entry(class).or_default();
        if outcome.is_ok() {
            entry.admitted += 1;
        } else {
            entry.refused += 1;
        }
        outcome
    }

    /// How many buckets are currently tracked. For tests and diagnostics.
    pub fn tracked(&self) -> usize {
        match self.state.lock() {
            Ok(state) => state.buckets.len(),
            Err(poisoned) => poisoned.into_inner().buckets.len(),
        }
    }

    /// Admitted and refused counts for every class, in [`Class::ALL`] order,
    /// for the `/metrics` counters. A class nothing has asked about yet
    /// answers zero rather than being absent, so the exposed series is
    /// stable from the first scrape. One case this cannot see: a
    /// [`Self::check_weighted`] call whose `cost` exceeds the class's own
    /// burst is refused before the lock these counts live behind is ever
    /// taken, since that answer needs no state at all - see
    /// [`Self::check_weighted_at`]'s own early return.
    pub fn counts(&self) -> Vec<(Class, ClassCounts)> {
        let state = match self.state.lock() {
            Ok(state) => state,
            Err(poisoned) => poisoned.into_inner(),
        };
        Class::ALL
            .iter()
            .map(|&class| (class, state.counts.get(&class).copied().unwrap_or_default()))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn burst_is_allowed_then_refused() {
        let limiter = RateLimiter::new();
        let now = Instant::now();
        let (burst, _) = Class::Password.budget();
        for i in 0..burst as usize {
            assert!(
                limiter.check_at(Class::Password, "1.2.3.4", now),
                "request {i} within the burst should pass"
            );
        }
        assert!(
            !limiter.check_at(Class::Password, "1.2.3.4", now),
            "the request past the burst is refused"
        );
    }

    /// A playing module scene must not be able to spend the allowance a
    /// person needs to send a message.
    ///
    /// Both module routes charged [`Class::Write`] until 2026-09-12, which is
    /// exactly what this asserts is no longer true: a Game of Life left
    /// running exhausted the write bucket, so it failed itself and would have
    /// taken message sends down with it. Separate buckets, separate fates.
    #[test]
    fn exhausting_the_module_budget_leaves_writes_alone() {
        let limiter = RateLimiter::new();
        let now = Instant::now();
        let (module_burst, _) = Class::Module.budget();

        // Spend every module token this account has, and then some.
        for _ in 0..(module_burst as usize * 2) {
            limiter.check_at(Class::Module, "1.2.3.4", now);
        }
        assert!(
            !limiter.check_at(Class::Module, "1.2.3.4", now),
            "the module bucket should be empty by now"
        );

        assert!(
            limiter.check_at(Class::Write, "1.2.3.4", now),
            "sending a message must not be refused because a board was playing"
        );
    }

    /// The other direction, so the separation is not a one-way accident: a
    /// person writing hard does not stop a board mid-frame either.
    #[test]
    fn exhausting_the_write_budget_leaves_modules_alone() {
        let limiter = RateLimiter::new();
        let now = Instant::now();
        let (write_burst, _) = Class::Write.budget();
        for _ in 0..(write_burst as usize * 2) {
            limiter.check_at(Class::Write, "1.2.3.4", now);
        }
        assert!(!limiter.check_at(Class::Write, "1.2.3.4", now));
        assert!(
            limiter.check_at(Class::Module, "1.2.3.4", now),
            "a playing board should survive somebody typing fast"
        );
    }

    /// Sized for an animating scene rather than inherited. Play asks roughly
    /// every 130ms, so a refill below about 7.7/s means it spends its life
    /// backing off; a ceiling above Canvas would be charging less for a
    /// sandboxed execution than for a row write.
    #[test]
    fn the_module_budget_suits_a_playing_scene() {
        let (burst, refill) = Class::Module.budget();
        assert!(
            refill >= 7.7,
            "a playing scene ticks faster than {refill}/s"
        );
        assert!(
            refill <= Class::Canvas.budget().1,
            "a wasm execution should not be cheaper than a canvas write"
        );
        assert!(burst >= refill, "a burst below the refill is not a burst");
    }

    /// The `/metrics` counters: admitted and refused are counted separately,
    /// not the same event read twice. Mutation-tested: always incrementing
    /// `admitted` regardless of outcome leaves every other test in this
    /// module green and fails only this one, on the `refused` assertion.
    #[test]
    fn counts_separates_admitted_from_refused() {
        let limiter = RateLimiter::new();
        let now = Instant::now();
        let (burst, _) = Class::Password.budget();
        for _ in 0..burst as usize {
            assert!(limiter.check_at(Class::Password, "counted", now));
        }
        assert!(!limiter.check_at(Class::Password, "counted", now));

        let counts = limiter.counts();
        let password = counts
            .iter()
            .find(|(class, _)| *class == Class::Password)
            .map(|(_, count)| *count)
            .expect("Password is in Class::ALL");
        assert_eq!(password.admitted, burst as u64);
        assert_eq!(password.refused, 1);

        // A class nothing has touched answers zero, not absent.
        let untouched = counts
            .iter()
            .find(|(class, _)| *class == Class::Upload)
            .map(|(_, count)| *count)
            .expect("Upload is in Class::ALL");
        assert_eq!(untouched.admitted, 0);
        assert_eq!(untouched.refused, 0);
    }

    #[test]
    fn tokens_refill_over_time() {
        let limiter = RateLimiter::new();
        let start = Instant::now();
        let (burst, refill) = Class::Password.budget();
        for _ in 0..burst as usize {
            assert!(limiter.check_at(Class::Password, "k", start));
        }
        assert!(!limiter.check_at(Class::Password, "k", start));

        // Exactly one token's worth of time restores exactly one request.
        let later = start + Duration::from_secs_f64(1.0 / refill);
        assert!(limiter.check_at(Class::Password, "k", later));
        assert!(!limiter.check_at(Class::Password, "k", later));
    }

    #[test]
    fn keys_and_classes_are_independent() {
        let limiter = RateLimiter::new();
        let now = Instant::now();
        let (burst, _) = Class::Password.budget();
        for _ in 0..burst as usize {
            assert!(limiter.check_at(Class::Password, "a", now));
        }
        assert!(!limiter.check_at(Class::Password, "a", now));
        // A different caller is unaffected.
        assert!(limiter.check_at(Class::Password, "b", now));
        // So is the same caller in a different class.
        assert!(limiter.check_at(Class::Write, "a", now));
    }

    #[test]
    fn idle_buckets_are_swept() {
        let limiter = RateLimiter::new();
        let start = Instant::now();
        assert!(limiter.check_at(Class::Write, "gone", start));
        assert_eq!(limiter.tracked(), 1);

        // Past the idle TTL, a later touch sweeps the stale bucket.
        let later = start + IDLE_TTL + SWEEP_INTERVAL;
        assert!(limiter.check_at(Class::Write, "fresh", later));
        assert_eq!(limiter.tracked(), 1, "the idle bucket was swept");
    }

    /// `check_at` is `check_weighted_at` at cost 1.0, not a second code path,
    /// so this is what actually proves the refactor kept every existing
    /// caller's behaviour: two big frames spend the burst exactly as two big
    /// requests would.
    #[test]
    fn weighted_cost_is_charged_per_call() {
        let limiter = RateLimiter::new();
        let now = Instant::now();
        let (burst, _) = Class::CanvasStrokePreview.budget();
        let half = burst / 2.0;
        assert!(limiter.check_weighted_at(Class::CanvasStrokePreview, "a", half, now));
        assert!(limiter.check_weighted_at(Class::CanvasStrokePreview, "a", half, now));
        assert!(
            !limiter.check_weighted_at(Class::CanvasStrokePreview, "a", 1.0, now),
            "the burst is fully spent"
        );
    }

    /// A frame nobody's own throttle could have produced is refused outright,
    /// on its own, rather than partially admitted against an
    /// under-provisioned bucket.
    #[test]
    fn a_cost_larger_than_the_burst_is_always_refused() {
        let limiter = RateLimiter::new();
        let (burst, _) = Class::CanvasStrokePreview.budget();
        assert!(!limiter.check_weighted_at(
            Class::CanvasStrokePreview,
            "a",
            burst + 1.0,
            Instant::now(),
        ));
    }

    /// The property the byte-rate cap exists for: a caller sending many small
    /// frames survives longer than one sending the same total bytes in fewer,
    /// larger ones - the opposite of a per-request cap, which would treat
    /// both identically. Mutation-tested by hand: reverting
    /// `check_weighted_at` to always charge 1.0 regardless of `cost` makes
    /// both assertions below pass identically, which is exactly the
    /// regression this test is for.
    #[test]
    fn many_small_frames_cost_less_than_few_large_ones_of_the_same_total() {
        let limiter = RateLimiter::new();
        let now = Instant::now();
        let (burst, _) = Class::CanvasStrokePreview.budget();

        let small_admitted = (0..1000)
            .filter(|_| limiter.check_weighted_at(Class::CanvasStrokePreview, "small", 1.0, now))
            .count();
        let large_admitted = (0..1000)
            .filter(|_| limiter.check_weighted_at(Class::CanvasStrokePreview, "large", burst, now))
            .count();

        assert!(small_admitted > large_admitted);
        assert_eq!(
            large_admitted, 1,
            "the first full-burst frame spends it all"
        );
    }

    #[test]
    fn a_refusal_says_how_long_until_the_next_token() {
        let limiter = RateLimiter::new();
        let start = Instant::now();
        let (burst, refill) = Class::Password.budget();
        for _ in 0..burst as usize {
            assert!(limiter.admit_at(Class::Password, "k", 1.0, start).is_ok());
        }
        let wait = limiter
            .admit_at(Class::Password, "k", 1.0, start)
            .unwrap_err();
        assert_eq!(wait, RetryAfter((1.0 / refill).ceil().max(1.0) as u64));
        let later = start + Duration::from_secs(wait.0);
        assert!(
            limiter.admit_at(Class::Password, "k", 1.0, later).is_ok(),
            "waiting the advertised time is enough"
        );
    }
}
