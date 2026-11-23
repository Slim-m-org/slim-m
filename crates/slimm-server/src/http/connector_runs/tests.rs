// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The waiting-run table: caps, who may answer, and what a dropped run frees.

use super::*;

#[test]
fn a_connector_holds_at_most_its_cap_and_a_member_their_share() {
    let runs = ConnectorRuns::default();
    let principal = UserId::generate();
    let mut held = Vec::new();
    for _ in 0..MAX_IN_FLIGHT / MAX_IN_FLIGHT_PER_MEMBER {
        let member = UserId::generate();
        for _ in 0..MAX_IN_FLIGHT_PER_MEMBER {
            held.push(
                runs.admit("pelican", principal, member)
                    .expect("under the cap"),
            );
        }
        assert!(
            runs.admit("pelican", principal, member).is_none(),
            "one member past their share"
        );
    }
    assert!(
        runs.admit("pelican", principal, UserId::generate())
            .is_none(),
        "the connector past its cap"
    );
    assert!(
        runs.admit("other", UserId::generate(), UserId::generate())
            .is_some(),
        "another connector has its own cap"
    );
    held.pop();
    assert!(
        runs.admit("pelican", principal, UserId::generate())
            .is_some(),
        "a finished run frees its slot"
    );
}

#[tokio::test]
async fn only_the_connector_it_was_sent_to_answers_a_run_and_only_once() {
    let runs = ConnectorRuns::default();
    let principal = UserId::generate();
    let (in_flight, answered) = runs
        .admit("pelican", principal, UserId::generate())
        .unwrap();
    let run_id = in_flight.run_id;
    assert!(!runs.answer(UserId::generate(), run_id, b"x".to_vec()));
    assert!(!runs.answer(principal, Uuid::now_v7(), b"x".to_vec()));
    assert!(runs.answer(principal, run_id, b"ok".to_vec()));
    assert!(
        !runs.answer(principal, run_id, b"again".to_vec()),
        "a run is answered once"
    );
    assert_eq!(answered.await.unwrap(), b"ok");
}

#[test]
fn a_run_that_timed_out_cannot_be_answered_late() {
    let runs = ConnectorRuns::default();
    let principal = UserId::generate();
    let (in_flight, _answered) = runs
        .admit("pelican", principal, UserId::generate())
        .unwrap();
    let run_id = in_flight.run_id;
    drop(in_flight);
    assert!(!runs.answer(principal, run_id, b"late".to_vec()));
    let waiting = runs.lock();
    assert!(
        waiting.runs.is_empty() && waiting.per_module.is_empty() && waiting.per_member.is_empty()
    );
}

#[test]
fn an_answer_is_the_wasm_response_shape() {
    assert!(well_formed(br#"{"ok": true, "output": "hi"}"#));
    assert!(well_formed(br#"{"ok": false, "error": "no"}"#));
    assert!(!well_formed(br#"{"ok": true}"#));
    assert!(!well_formed(br#"{"ok": false, "output": "hi"}"#));
    assert!(!well_formed(b"hi"));
}
