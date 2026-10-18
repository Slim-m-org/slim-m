// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Keeps the shared broadcast rings small: their memory is capacity times `size_of::<Event>()`.

use super::{CHANNEL_CAPACITY, EPHEMERAL_CHANNEL_CAPACITY, Event};

/// A variant carrying its payload inline rather than behind an `Arc` or `Box` trips this.
const MAX_EVENT_BYTES: usize = 192;

/// Upper bound for both rings together, so raising a capacity is a deliberate act.
const MAX_RING_BYTES: usize = 2 * 1024 * 1024;

#[test]
fn event_stays_small() {
    let size = std::mem::size_of::<Event>();
    assert!(
        size <= MAX_EVENT_BYTES,
        "Event is {size} bytes; box or Arc the large variant"
    );
}

#[test]
fn both_rings_stay_under_budget() {
    let ring = (CHANNEL_CAPACITY + EPHEMERAL_CHANNEL_CAPACITY) * std::mem::size_of::<Event>();
    assert!(ring <= MAX_RING_BYTES, "rings hold {ring} bytes");
}
