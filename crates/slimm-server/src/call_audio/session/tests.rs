// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::*;

fn subject() -> Subject {
    Subject {
        module_id: "transcript".into(),
        module_name: "Transcript".into(),
        purpose: "writes it down".into(),
        keeps: "the text".into(),
    }
}

fn people(n: usize) -> Vec<UserId> {
    (0..n).map(|_| UserId::generate()).collect()
}

fn ask(present: &[UserId], by: UserId, now: i64) -> (Session, Vec<Effect>) {
    Session::request(
        (Uuid::now_v7(), ChannelId::generate(), subject()),
        by,
        present,
        now,
    )
    .expect("fits")
}

fn on(present: &[UserId]) -> Session {
    let (mut s, _) = ask(present, present[0], 0);
    for u in &present[1..] {
        s.consent(*u, true, 1).unwrap();
    }
    assert_eq!(s.status, Status::On);
    s
}

#[test]
fn a_lone_requester_starts_at_once() {
    let p = people(1);
    let (s, effects) = ask(&p, p[0], 5);
    assert_eq!(effects, vec![Effect::Start]);
    assert_eq!(s.status, Status::On);
    assert_eq!(s.started_at_ms, Some(5));
    assert_eq!(s.include(), vec![p[0]]);
}

#[test]
fn it_starts_only_when_everyone_has_said_yes() {
    let p = people(3);
    let (mut s, effects) = ask(&p, p[0], 0);
    assert!(effects.is_empty());
    assert_eq!(s.status, Status::Asking);
    assert_eq!(
        s.include(),
        vec![p[0]],
        "the requester's press is their yes"
    );
    assert!(s.consent(p[1], true, 10).unwrap().is_empty());
    assert_eq!(s.status, Status::Asking);
    assert_eq!(s.consent(p[2], true, 20).unwrap(), vec![Effect::Start]);
    assert_eq!(s.status, Status::On);
    assert_eq!(s.started_at_ms, Some(20));
    assert_eq!(s.include().len(), 3);
}

#[test]
fn a_no_ends_the_ask_without_starting() {
    let p = people(3);
    let (mut s, _) = ask(&p, p[0], 0);
    let effects = s.consent(p[1], false, 1).unwrap();
    assert_eq!(
        effects,
        vec![Effect::Ended {
            reason: EndReason::Declined,
            was_on: false
        }]
    );
    assert!(!s.include().contains(&p[1]));
}

#[test]
fn the_ask_lapses_after_sixty_seconds_and_not_before() {
    let p = people(2);
    let (s, _) = ask(&p, p[0], 1_000);
    assert!(s.tick(60_999).is_empty());
    assert_eq!(
        s.tick(61_000),
        vec![Effect::Ended {
            reason: EndReason::Lapsed,
            was_on: false
        }]
    );
    assert_eq!(EndReason::Lapsed.wire(), "declined");
}

#[test]
fn a_joiner_is_left_out_until_they_say_yes() {
    let p = people(2);
    let mut s = on(&p);
    let joiner = UserId::generate();
    assert!(s.join(joiner).is_empty());
    assert_eq!(s.pending(), vec![joiner]);
    assert!(
        !s.include().contains(&joiner),
        "never included while pending"
    );
    let effects = s.consent(joiner, true, 100).unwrap();
    assert_eq!(
        effects,
        vec![
            Effect::Participant {
                user_id: joiner,
                included: true
            },
            Effect::Include
        ]
    );
    assert!(s.include().contains(&joiner));
}

#[test]
fn a_joiner_who_says_no_stops_it_for_everyone() {
    let p = people(2);
    let mut s = on(&p);
    let joiner = UserId::generate();
    s.join(joiner);
    let effects = s.consent(joiner, false, 5).unwrap();
    assert_eq!(
        effects,
        vec![Effect::Ended {
            reason: EndReason::Declined,
            was_on: true
        }]
    );
}

#[test]
fn a_joiner_who_stays_silent_stays_out_and_the_session_goes_on() {
    let p = people(2);
    let mut s = on(&p);
    let joiner = UserId::generate();
    s.join(joiner);
    assert!(s.tick(30 * 60_000).is_empty());
    assert_eq!(s.status, Status::On);
    assert!(!s.include().contains(&joiner));
}

#[test]
fn a_leaver_drops_out_of_the_include_set() {
    let p = people(3);
    let mut s = on(&p);
    let effects = s.leave(p[2], 9);
    assert_eq!(
        effects,
        vec![
            Effect::Participant {
                user_id: p[2],
                included: false
            },
            Effect::Include
        ]
    );
    assert_eq!(s.include().len(), 2);
}

#[test]
fn the_last_person_leaving_ends_it() {
    let p = people(2);
    let mut s = on(&p);
    s.leave(p[0], 1);
    assert_eq!(
        s.leave(p[1], 2),
        vec![Effect::Ended {
            reason: EndReason::CallEnded,
            was_on: true
        }]
    );
}

#[test]
fn an_unanswered_person_leaving_can_complete_the_ask() {
    let p = people(2);
    let (mut s, _) = ask(&p, p[0], 0);
    assert_eq!(s.leave(p[1], 3), vec![Effect::Start]);
}

#[test]
fn the_requester_leaving_during_the_ask_cancels_it() {
    let p = people(2);
    let (mut s, _) = ask(&p, p[0], 0);
    assert_eq!(
        s.leave(p[0], 3),
        vec![Effect::Ended {
            reason: EndReason::Stopped,
            was_on: false
        }]
    );
}

#[test]
fn only_someone_in_the_call_can_answer_or_stop() {
    let p = people(2);
    let (mut s, _) = ask(&p, p[0], 0);
    let stranger = UserId::generate();
    assert_eq!(s.consent(stranger, true, 1), Err(Refused::NotInCall));
    assert_eq!(s.stop(stranger), Err(Refused::NotInCall));
    assert_eq!(
        s.stop(p[1]).unwrap(),
        vec![Effect::Ended {
            reason: EndReason::Stopped,
            was_on: false
        }]
    );
}

#[test]
fn it_stops_after_four_hours() {
    let p = people(1);
    let (s, _) = ask(&p, p[0], 100);
    assert!(s.tick(100 + TIME_LIMIT_MS - 1).is_empty());
    assert_eq!(
        s.tick(100 + TIME_LIMIT_MS),
        vec![Effect::Ended {
            reason: EndReason::TimeLimit,
            was_on: true
        }]
    );
}

#[test]
fn a_call_too_large_to_hold_cannot_be_asked() {
    let p = people(MAX_INCLUDED + 1);
    let made = Session::request(
        (Uuid::now_v7(), ChannelId::generate(), subject()),
        p[0],
        &p,
        0,
    );
    assert!(made.is_none());
}

#[test]
fn later_joiners_past_the_cap_are_not_asked() {
    let p = people(MAX_INCLUDED);
    let mut s = on(&p);
    assert!(s.is_full());
    let late = UserId::generate();
    s.join(late);
    assert_eq!(s.answer_of(late), None);
    assert!(!s.include().contains(&late));
}

#[test]
fn the_include_set_never_holds_a_pending_or_declined_person() {
    let p = people(5);
    let (mut s, _) = ask(&p, p[0], 0);
    s.consent(p[1], true, 1).unwrap();
    for u in s.include() {
        assert_eq!(s.answer_of(u), Some(Answer::Yes));
    }
    assert!(!s.include().contains(&p[2]));
    s.consent(p[3], false, 2).unwrap();
    assert!(!s.include().contains(&p[3]));
}

#[test]
fn refusals_start_a_cooldown_and_outside_endings_do_not() {
    for r in [EndReason::Declined, EndReason::Lapsed, EndReason::Stopped] {
        assert!(r.is_refusal());
    }
    for r in [
        EndReason::CallEnded,
        EndReason::Overload,
        EndReason::TimeLimit,
    ] {
        assert!(!r.is_refusal());
    }
}
