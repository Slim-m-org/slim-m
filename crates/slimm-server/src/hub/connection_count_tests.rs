// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The hub's live connection count; split from `hub.rs` for its line budget.

use super::*;

#[test]
fn tracks_held_permits_directly() {
    let hub = Hub::new();
    assert_eq!(hub.connection_count(), 0);

    let first = hub.try_connect().expect("a slot is free");
    assert_eq!(hub.connection_count(), 1);
    let second = hub.try_connect().expect("a slot is free");
    assert_eq!(hub.connection_count(), 2);

    drop(first);
    assert_eq!(hub.connection_count(), 1);
    drop(second);
    assert_eq!(hub.connection_count(), 0);
}
