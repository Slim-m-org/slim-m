// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::*;

fn uid() -> UserId {
    UserId::generate()
}

fn cid() -> ChannelId {
    ChannelId::generate()
}

/// A ring whose caller is already in the call, so it went out.
fn ring(rings: &CallRings, channel: ChannelId, caller: UserId, callees: &[UserId]) -> CallRingId {
    let ring_id = rings.start(channel, caller, callees).0;
    assert_eq!(
        rings.announce(channel, caller).map(|(id, _)| id),
        Some(ring_id)
    );
    ring_id
}

#[test]
fn the_callee_answering_clears_the_ring_and_reports_its_id() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    let ring_id = ring(&rings, channel, caller, &[callee]);

    assert_eq!(
        rings.answer(channel, callee).map(|(id, _)| id),
        Some(ring_id)
    );
    // Answered rings do not answer twice.
    assert_eq!(rings.answer(channel, callee), None);
}

/// The sweep and an answer are mutually exclusive, whichever lands first.
///
/// `http::voice::heartbeat` claims the ring BEFORE recording the join for
/// exactly this reason. With the record first there was a window in which
/// the sweep could take the ring after the callee had already joined,
/// publishing `TimedOut` and evicting the caller while someone sat in the
/// room alone. These two assertions are what makes that impossible: only
/// one of the pair can ever succeed for a given ring.
#[test]
fn a_swept_ring_can_no_longer_be_answered() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    ring(&rings, channel, caller, &[callee]);

    let swept = rings.sweep_stale_at(Instant::now() + RING_TIMEOUT);
    assert_eq!(swept.len(), 1, "sanity: the ring really did time out");
    assert_eq!(
        rings.answer(channel, callee),
        None,
        "a swept ring must not also report as answered"
    );
}

#[test]
fn an_answered_ring_is_no_longer_there_for_the_sweep_to_time_out() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    ring(&rings, channel, caller, &[callee]);

    assert!(rings.answer(channel, callee).is_some());
    assert!(
        rings
            .sweep_stale_at(Instant::now() + RING_TIMEOUT)
            .is_empty(),
        "an answered ring must not later be swept as timed out"
    );
}

#[test]
fn a_ring_past_its_timeout_is_not_listed_as_outstanding() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    ring(&rings, channel, caller, &[callee]);
    let now = Instant::now();

    assert_eq!(rings.outstanding_for_at(callee, now).len(), 1);
    assert!(rings.outstanding_for_at(caller, now).is_empty());
    assert!(
        rings
            .outstanding_for_at(callee, now + RING_TIMEOUT)
            .is_empty()
    );
}

#[test]
fn a_stray_heartbeat_from_somebody_else_does_not_answer_the_ring() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    ring(&rings, channel, caller, &[callee]);

    assert_eq!(rings.answer(channel, uid()), None, "not the named callee");
    // Still outstanding: a real answer from the actual callee still works.
    assert!(rings.answer(channel, callee).is_some());
}

#[test]
fn declining_clears_the_ring_and_reports_the_caller_to_evict() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    let ring_id = ring(&rings, channel, caller, &[callee]);

    assert_eq!(
        rings.decline(channel, callee),
        Some(Declined {
            ring_id,
            caller_id: caller,
            ended: true
        })
    );
    assert_eq!(rings.decline(channel, callee), None);
}

#[test]
fn a_group_ring_answers_for_everyone_when_any_callee_joins() {
    let rings = CallRings::new();
    let (channel, caller, first, second) = (cid(), uid(), uid(), uid());
    let ring_id = ring(&rings, channel, caller, &[first, second]);

    assert_eq!(rings.outstanding_for_at(second, Instant::now()).len(), 1);
    assert_eq!(
        rings.answer(channel, first).map(|(id, _)| id),
        Some(ring_id)
    );
    assert_eq!(rings.answer(channel, second), None, "already answered");
    assert!(rings.outstanding_for_at(second, Instant::now()).is_empty());
}

#[test]
fn a_group_ring_goes_on_until_the_last_callee_declines() {
    let rings = CallRings::new();
    let (channel, caller, first, second) = (cid(), uid(), uid(), uid());
    let ring_id = ring(&rings, channel, caller, &[first, second]);

    let one = rings.decline(channel, first).expect("first decline");
    assert!(!one.ended);
    assert_eq!(rings.decline(channel, first), None, "declined twice");
    assert!(rings.outstanding_for_at(first, Instant::now()).is_empty());
    assert_eq!(rings.outstanding_for_at(second, Instant::now()).len(), 1);

    let last = rings.decline(channel, second).expect("last decline");
    assert_eq!(
        (last.ring_id, last.caller_id, last.ended),
        (ring_id, caller, true)
    );
    assert!(
        rings
            .sweep_stale_at(Instant::now() + RING_TIMEOUT)
            .is_empty()
    );
}

#[test]
fn the_caller_canceling_is_matched_on_the_caller_not_the_callee() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    let ring_id = ring(&rings, channel, caller, &[callee]);

    assert_eq!(rings.cancel(channel, callee), None, "not the caller");
    assert_eq!(
        rings.cancel(channel, caller),
        Some(Canceled {
            ring_id,
            announced: true,
            heard: true
        })
    );
}

#[test]
fn starting_a_second_ring_for_the_same_channel_replaces_the_first() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    let first = ring(&rings, channel, caller, &[callee]);
    let second = ring(&rings, channel, caller, &[callee]);

    assert_ne!(first, second, "each attempt mints a fresh id");
    assert_eq!(
        rings.answer(channel, callee).map(|(id, _)| id),
        Some(second)
    );
}

#[test]
fn a_ring_under_the_timeout_is_not_swept() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    ring(&rings, channel, caller, &[callee]);

    assert!(
        rings
            .sweep_stale_at(Instant::now() + RING_TIMEOUT - Duration::from_secs(1))
            .is_empty()
    );
}

#[test]
fn a_ring_past_the_timeout_is_swept_and_reports_the_caller() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    let ring_id = ring(&rings, channel, caller, &[callee]);

    let past = Instant::now() + RING_TIMEOUT + Duration::from_secs(1);
    assert_eq!(
        rings.sweep_stale_at(past),
        [StaleRing {
            channel_id: channel,
            ring_id,
            caller_id: caller,
            announced: true,
            heard: true
        }]
    );
    // Swept once, so a later pass over the same instant finds nothing left.
    assert!(rings.sweep_stale_at(past).is_empty());
}

#[test]
fn every_outcome_has_a_distinct_stable_wire_string() {
    let strings: std::collections::HashSet<&str> = [
        CallRingOutcome::Answered,
        CallRingOutcome::Declined,
        CallRingOutcome::Canceled,
        CallRingOutcome::TimedOut,
    ]
    .map(CallRingOutcome::as_str)
    .into_iter()
    .collect();
    assert_eq!(strings.len(), 4);
}

#[test]
fn a_ring_is_not_outstanding_until_its_caller_is_in_the_call() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    let ring_id = rings.start(channel, caller, &[callee]).0;

    assert!(rings.outstanding_for_at(callee, Instant::now()).is_empty());
    assert_eq!(
        rings.announce(channel, callee),
        None,
        "only the caller announces"
    );
    assert_eq!(
        rings.announce(channel, caller),
        Some((ring_id, vec![callee]))
    );
    assert_eq!(rings.announce(channel, caller), None, "announced once");
    assert_eq!(rings.outstanding_for_at(callee, Instant::now()).len(), 1);
}

#[test]
fn a_ring_whose_caller_never_joined_is_swept_as_never_announced() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    let ring_id = rings.start(channel, caller, &[callee]).0;

    let past = Instant::now() + RING_TIMEOUT + Duration::from_secs(1);
    let swept = rings.sweep_stale_at(past);
    assert_eq!(swept.len(), 1);
    assert_eq!((swept[0].ring_id, swept[0].announced), (ring_id, false));
}

#[test]
fn canceling_a_ring_nobody_heard_says_so() {
    let rings = CallRings::new();
    let (channel, caller, callee) = (cid(), uid(), uid());
    let ring_id = rings.start(channel, caller, &[callee]).0;

    assert_eq!(
        rings.cancel(channel, caller),
        Some(Canceled {
            ring_id,
            announced: false,
            heard: false
        })
    );
}

#[test]
fn a_quiet_callee_is_rung_but_never_told() {
    let rings = CallRings::new();
    let (channel, caller, quiet) = (cid(), uid(), uid());
    let ring_id = rings
        .start_with_quiet(channel, caller, &[quiet], &[quiet])
        .0;

    assert_eq!(rings.announce(channel, caller), Some((ring_id, vec![])));
    assert!(rings.outstanding_for_at(quiet, Instant::now()).is_empty());
    let past = Instant::now() + RING_TIMEOUT + Duration::from_secs(1);
    let swept = rings.sweep_stale_at(past);
    assert_eq!((swept[0].announced, swept[0].heard), (true, false));
}
