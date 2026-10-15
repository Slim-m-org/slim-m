// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use std::time::{Duration, Instant};

use super::super::{MAX_BUCKETS, RateLimiter};
use super::*;

/// Fills the map with anonymous keys that each spent their whole burst at `at`.
fn fill_spent(limiter: &RateLimiter, at: Instant) {
    let (burst, _) = Class::Password.budget();
    for i in 0..MAX_BUCKETS {
        assert!(limiter.check_weighted_at(
            Class::Password,
            &format!("ip:10.0.{}.{}", i / 256, i % 256),
            burst,
            at
        ));
    }
}

#[test]
fn a_full_map_of_refilled_buckets_still_admits_a_new_caller() {
    let limiter = RateLimiter::new();
    let start = Instant::now();
    fill_spent(&limiter, start);
    let (burst, refill) = Class::Password.budget();
    let refilled = start + Duration::from_secs_f64(burst / refill + 1.0);
    assert!(limiter.check_at(Class::Password, "ip:192.0.2.1", refilled));
    assert!(
        limiter.tracked() < MAX_BUCKETS,
        "refilled buckets were dropped"
    );
}

#[test]
fn a_full_map_of_throttled_buckets_refuses_anonymous_callers_but_not_members() {
    let limiter = RateLimiter::new();
    let start = Instant::now();
    fill_spent(&limiter, start);
    let soon = start + Duration::from_millis(10);
    assert!(
        !limiter.check_at(Class::Password, "ip:192.0.2.1", soon),
        "a fresh anonymous key cannot grow a full map"
    );
    assert!(
        limiter.check_at(Class::Write, "u:019fa3ad-4dc8-7cb3-940a-a297eae87adf", soon),
        "a member is not locked out by someone else's flood"
    );
}

#[test]
fn members_are_bounded_too() {
    let limiter = RateLimiter::new();
    let start = Instant::now();
    fill_spent(&limiter, start);
    let soon = start + Duration::from_millis(10);
    for i in 0..MEMBER_HEADROOM {
        assert!(limiter.check_at(Class::Write, &format!("u:{i}"), soon));
    }
    assert!(!limiter.check_at(Class::Write, "u:one-too-many", soon));
}

#[test]
fn only_ip_keys_count_as_anonymous() {
    assert!(is_anonymous("ip:192.0.2.1"));
    assert!(is_anonymous("ip:2001:db8::/64"));
    assert!(!is_anonymous("u:019fa3ad-4dc8-7cb3-940a-a297eae87adf"));
    assert!(!is_anonymous("m:feeds"));
}
