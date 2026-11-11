// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the module is sent about a call it hears (decision 0105): four events
//! in the `event/1` envelope, straight to its queue, needing no subscription.

use serde_json::json;
use slimm_server::call_audio::session::EndReason;

mod support;
use support::call_audio_world::{MODULE, Rig, now_ms};
use support::wait::wait_for;

async fn started_rig(name: &str) -> Rig {
    let rig = Rig::start(name, 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    rig.join(a).await;
    rig.join(b).await;
    rig.ask(a).await;
    rig.answer(b, true).await;
    rig.wait_session(Some("on")).await;
    wait_for("the listener to be told to start", || {
        let started = !rig.listener.of_type("start").is_empty();
        async move { started.then_some(()) }
    })
    .await;
    rig
}

#[tokio::test]
async fn started_segments_and_stopped_arrive_with_the_documented_fields() {
    let rig = started_rig("call-audio-events").await;
    let (a, b) = (rig.people[0].id.to_string(), rig.people[1].id.to_string());
    wait_for("start", || {
        let n = rig.listener.of_type("start").len();
        async move { (n == 1).then_some(()) }
    })
    .await;
    let session = rig.session_id();
    rig.listener.segment(&session, &a, "hello everyone");
    rig.listener.segment(&session, &b, "hi there");
    rig.recorded(3).await;
    rig.stop(&rig.people[1]).await;
    let events = rig.recorded(4).await;

    assert_eq!(events[0]["event"], "call.audio.started");
    assert_eq!(events[0]["$slim"], "event/1");
    assert_eq!(events[0]["data"]["session_id"], session);
    assert_eq!(events[0]["data"]["channel_id"], rig.channel.to_string());
    assert_eq!(events[0]["data"]["included"].as_array().unwrap().len(), 2);
    let names = events[0]["data"]["names"].as_object().unwrap();
    assert_eq!(names.len(), 2);
    for person in &rig.people {
        let user = rig.store.user_profiles(&[person.id]).await.unwrap();
        assert_eq!(names[&person.id.to_string()], user[0].display_name.as_str());
    }
    assert!(
        events[0]["id"]
            .as_str()
            .unwrap()
            .starts_with(&format!("call-audio:{session}:"))
    );

    let segments: Vec<_> = events
        .iter()
        .filter(|e| e["event"] == "call.audio.segment")
        .collect();
    assert_eq!(segments.len(), 2);
    let first = segments.iter().find(|e| e["data"]["user_id"] == a).unwrap();
    assert_eq!(first["data"]["text"], "hello everyone");
    assert_eq!(first["data"]["language"], "en");
    assert!(first["data"]["start_ms"].as_i64().unwrap() > 1000);
    assert!(
        first["data"]["end_ms"].as_i64().unwrap() > first["data"]["start_ms"].as_i64().unwrap()
    );

    let stopped = events.last().unwrap();
    assert_eq!(stopped["event"], "call.audio.stopped");
    assert_eq!(stopped["data"]["reason"], "stopped");
    assert_eq!(stopped["data"]["segments_sent"], 2);
    assert!(
        !stopped["data"].to_string().contains(&b),
        "never names who stopped it"
    );
}

#[tokio::test]
async fn a_segment_from_someone_not_in_the_include_set_is_never_delivered() {
    let rig = started_rig("call-audio-events-filter").await;
    let joiner = rig.store.create_user("late", "Late").await.unwrap().id;
    let session = rig.session_id();
    rig.listener
        .segment(&session, &joiner.to_string(), "sneaky");
    rig.listener
        .segment(&session, &rig.people[0].id.to_string(), "legit");
    let events = rig.recorded(2).await;
    let texts: Vec<_> = events
        .iter()
        .filter(|e| e["event"] == "call.audio.segment")
        .map(|e| e["data"]["text"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(texts, ["legit"]);
}

#[tokio::test]
async fn a_participant_event_names_who_entered_or_left_the_include_set() {
    let rig = started_rig("call-audio-events-participant").await;
    let c = rig.store.create_user("c", "C").await.unwrap();
    let token = rig
        .store
        .open_session(c.id, "t")
        .await
        .unwrap()
        .access_token;
    let c = support::call_audio_world::Person { id: c.id, token };
    let first_name = rig.store.user_profiles(&[rig.people[0].id]).await.unwrap()[0]
        .display_name
        .clone();
    rig.join(&c).await;
    rig.answer(&c, true).await;
    rig.leave(&rig.people[0]).await;
    let events = rig.recorded(3).await;
    let changes: Vec<_> = events
        .iter()
        .filter(|e| e["event"] == "call.audio.participant")
        .map(|e| {
            (
                e["data"]["user_id"].as_str().unwrap().to_owned(),
                e["data"]["included"].as_bool().unwrap(),
                e["data"]["name"].as_str().map(str::to_owned),
            )
        })
        .collect();
    assert_eq!(
        changes,
        [
            (c.id.to_string(), true, Some("C".to_owned())),
            (rig.people[0].id.to_string(), false, Some(first_name))
        ]
    );
}

#[tokio::test]
async fn the_module_needs_no_subscription_and_a_disabled_module_is_sent_nothing() {
    let rig = started_rig("call-audio-events-disabled").await;
    assert!(
        rig.store
            .installed_module(MODULE)
            .await
            .unwrap()
            .unwrap()
            .subscriptions
            .is_empty()
    );
    rig.recorded(1).await;
    rig.store.set_module_enabled(MODULE, false).await.unwrap();
    let session = rig.session_id();
    rig.listener
        .segment(&session, &rig.people[0].id.to_string(), "after it was off");
    for outcome in rig.state.call_audio.tick(now_ms()) {
        let _ = outcome;
    }
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let events = rig.recorded(1).await;
    assert!(
        events.iter().all(|e| e["event"] != "call.audio.segment"),
        "{events:?}"
    );
}

#[tokio::test]
async fn a_session_ended_from_outside_reports_its_reason_to_the_module() {
    let rig = started_rig("call-audio-events-reason").await;
    rig.listener.ended(&rig.session_id(), "overload");
    let events = rig.recorded(2).await;
    let stopped = events
        .iter()
        .find(|e| e["event"] == "call.audio.stopped")
        .unwrap();
    assert_eq!(stopped["data"]["reason"], "overload");
    assert_eq!(EndReason::Overload.wire(), "overload");
    assert_eq!(json!(stopped["data"]["segments_sent"]), json!(0));
}
