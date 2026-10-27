// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::*;

fn uid() -> UserId {
    UserId::generate()
}

#[test]
fn hidden_reads_as_offline_to_others_but_true_to_self() {
    let alice = uid();
    let bob = uid();
    let status = status_for(bob, alice, Visibility::Hidden, true, false);
    assert_eq!(
        status,
        Status::Offline,
        "others see a hidden user as offline"
    );

    let self_status = status_for(alice, alice, Visibility::Hidden, true, false);
    assert_eq!(
        self_status,
        Status::Online,
        "the hidden user's own client sees their true state"
    );
}

#[test]
fn disconnected_is_always_offline_regardless_of_visibility() {
    let alice = uid();
    for visibility in [
        Visibility::Online,
        Visibility::Away,
        Visibility::Dnd,
        Visibility::Hidden,
    ] {
        assert_eq!(
            status_for(alice, alice, visibility, false, false),
            Status::Offline
        );
    }
}

#[test]
fn online_goes_away_when_idle() {
    let alice = uid();
    assert_eq!(
        status_for(alice, alice, Visibility::Online, true, false),
        Status::Online
    );
    assert_eq!(
        status_for(alice, alice, Visibility::Online, true, true),
        Status::Away
    );
}

#[test]
fn away_and_dnd_pass_through_while_connected() {
    let alice = uid();
    assert_eq!(
        status_for(alice, alice, Visibility::Away, true, false),
        Status::Away
    );
    assert_eq!(
        status_for(alice, alice, Visibility::Dnd, true, false),
        Status::Dnd
    );
}

#[test]
fn first_connect_and_last_disconnect_are_the_only_transitions() {
    let tracker = PresenceTracker::new();
    let alice = uid();

    assert!(tracker.connect(alice), "first connection is a transition");
    assert!(
        !tracker.connect(alice),
        "a second device is not a fresh transition"
    );
    assert!(tracker.is_connected(alice));

    assert!(
        !tracker.disconnect(alice),
        "one of two connections closing is not the last"
    );
    assert!(tracker.is_connected(alice), "still connected on the second");
    assert!(
        tracker.disconnect(alice),
        "the last connection closing is a transition"
    );
    assert!(!tracker.is_connected(alice));
}

#[test]
fn disconnect_without_a_matching_connect_is_a_no_op() {
    let tracker = PresenceTracker::new();
    assert!(!tracker.disconnect(uid()));
}

#[test]
fn idle_is_measured_from_last_activity() {
    let tracker = PresenceTracker::new();
    let alice = uid();
    let start = Instant::now();
    tracker.connect_at(alice, start);
    assert!(!tracker.is_idle_at(alice, start));

    let past_timeout = start + IDLE_TIMEOUT + Duration::from_secs(1);
    assert!(tracker.is_idle_at(alice, past_timeout));

    // A touch resets the clock even past the old timeout.
    tracker.touch_at(alice, past_timeout);
    assert!(!tracker.is_idle_at(alice, past_timeout));
}

#[test]
fn a_closing_socket_does_not_reset_the_idle_clock() {
    let tracker = PresenceTracker::new();
    let alice = uid();
    let long_ago = Instant::now() - IDLE_TIMEOUT - Duration::from_secs(1);
    tracker.connect_at(alice, long_ago);
    tracker.connect_at(alice, long_ago);

    tracker.disconnect(alice);
    assert!(tracker.is_idle(alice));
}

#[test]
fn visibility_is_cached_only_while_connected() {
    let tracker = PresenceTracker::new();
    let alice = uid();

    // Nothing to cache into before connecting: a no-op, still a miss.
    tracker.set_visibility(alice, Visibility::Hidden);
    assert_eq!(tracker.visibility(alice), None);

    tracker.connect(alice);
    // Connected but not loaded yet: a miss, so the caller reads the store.
    assert_eq!(tracker.visibility(alice), None);

    tracker.set_visibility(alice, Visibility::Hidden);
    assert_eq!(tracker.visibility(alice), Some(Visibility::Hidden));

    // A later change is reflected at once, never a stale cached choice.
    tracker.set_visibility(alice, Visibility::Online);
    assert_eq!(tracker.visibility(alice), Some(Visibility::Online));

    // Dropped with the last connection, so the next connect reloads fresh.
    tracker.disconnect(alice);
    assert_eq!(tracker.visibility(alice), None);
}

#[test]
fn a_racing_connect_load_never_clobbers_an_authoritative_change() {
    let tracker = PresenceTracker::new();
    let alice = uid();
    tracker.connect(alice);

    // The endpoint's authoritative write lands first.
    tracker.set_visibility(alice, Visibility::Hidden);
    // A racing connect load with the old value must not overwrite it.
    tracker.load_visibility(alice, Visibility::Online);
    assert_eq!(tracker.visibility(alice), Some(Visibility::Hidden));

    // A load into an empty slot still fills it, the ordinary connect path.
    tracker.disconnect(alice);
    tracker.connect(alice);
    tracker.load_visibility(alice, Visibility::Away);
    assert_eq!(tracker.visibility(alice), Some(Visibility::Away));
}
