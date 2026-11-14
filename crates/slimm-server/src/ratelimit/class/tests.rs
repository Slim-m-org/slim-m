// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Unit tests for the traffic classes and their budgets.
//!
//! Their own file rather than an inline module, so `class.rs` stays under the
//! review budget as classes keep being added.

use super::Class;

/// `ALL` and the enum come from one macro list, so this pins the property
/// the old hand-kept array could not: discriminants run 0..len with no gap,
/// which is only true when every variant is in it exactly once.
#[test]
fn all_lists_every_variant_exactly_once() {
    for (position, class) in Class::ALL.into_iter().enumerate() {
        assert_eq!(class as usize, position, "{class:?} is out of place in ALL");
    }
}

/// The label is a Prometheus dimension, so two classes sharing one would
/// silently merge their counters. Each must also be the lowercase snake_case
/// the doc promises a dashboard can key on.
#[test]
fn every_label_is_unique_and_snake_case() {
    let mut seen = std::collections::HashSet::new();
    for class in Class::ALL {
        let label = class.label();
        assert!(!label.is_empty(), "{class:?} has an empty label");
        assert!(
            label
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'),
            "{class:?} label {label:?} is not lowercase snake_case"
        );
        assert!(seen.insert(label), "two classes share the label {label:?}");
    }
}

/// A bucket with a non-positive burst can never admit a request, and a
/// non-positive refill never recovers one; either is a budget typo that
/// would wedge every caller of that class.
#[test]
fn every_budget_is_positive() {
    for class in Class::ALL {
        let (burst, refill) = class.budget();
        assert!(burst > 0.0, "{class:?} has a non-positive burst {burst}");
        assert!(refill > 0.0, "{class:?} has a non-positive refill {refill}");
    }
}

/// The whole point of giving a ring its own class is that it is cheaper
/// to send than it is to receive: one request wakes a device, starts a
/// looping tone and raises a window. On `Write`'s budget a contact could
/// sustain five of those a second, and since a fresh ring replaces the
/// outstanding one that needs no cooperation from the callee. If this
/// ever loosens back to `Write`, the throttle has quietly gone.
#[test]
fn ringing_is_throttled_harder_than_an_ordinary_write() {
    let (ring_burst, ring_refill) = Class::Ring.budget();
    let (write_burst, write_refill) = Class::Write.budget();
    assert!(
        ring_refill < write_refill,
        "ring refill {ring_refill} is not tighter than write's {write_refill}"
    );
    assert!(
        ring_burst < write_burst,
        "ring burst {ring_burst} is not tighter than write's {write_burst}"
    );
    assert!(
        write_refill / ring_refill >= 10.0,
        "ring is only {}x tighter than write; that is not a throttle",
        write_refill / ring_refill
    );
}

/// A clip is a noise in everyone's ears, so the budget is exactly one play
/// every three seconds with no burst to spend on top.
#[test]
fn a_soundboard_play_is_one_every_three_seconds() {
    let (burst, refill) = Class::Soundboard.budget();
    assert_eq!(burst, 1.0);
    assert!((1.0 / refill - 3.0).abs() < 1e-9, "refill {refill}");
}

/// The lockout, not this bucket, has to be what stops somebody grinding a
/// six-digit code: a per-address budget at or below the per-account failure
/// limit means the limiter answers first, the lockout never fires, and an
/// office sharing one address shares one account's worth of attempts.
#[test]
fn the_totp_burst_leaves_room_for_the_account_lockout_to_fire() {
    let (burst, refill) = Class::Totp.budget();
    assert!(
        burst > crate::totp::MAX_FAILURES as f64,
        "burst {burst} does not exceed the {} failures that lock a factor",
        crate::totp::MAX_FAILURES
    );
    assert!(
        refill < Class::Password.budget().1,
        "presenting a code should be throttled harder than presenting a password"
    );
}

/// A webhook delivery wakes every phone in the community, not just one -
/// a bigger amplification than a ring's single device - so its sustained
/// rate must stay well under one per second, and its burst must still
/// absorb an honest alert-feed flurry (this variant's own doc names
/// thirty).
#[test]
fn webhook_delivery_is_throttled_well_under_once_a_second() {
    let (burst, refill) = Class::Webhook.budget();
    assert!(
        refill < 1.0,
        "webhook refill {refill} is not well under one per second"
    );
    assert!(
        burst >= 30.0,
        "webhook burst {burst} does not cover a thirty-item import"
    );
}
