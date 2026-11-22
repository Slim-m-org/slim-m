// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared room state (decision 0131) when things go wrong: a failing module
//! leaves the state as it was and counts toward its breaker, every cap holds,
//! and a module going off takes its rooms with it.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::support;
use support::room_world::{
    RoomWorld, canned_room_wasm, marker_fails_wasm, noughts_wasm, room_world,
};
use support::ws::{connect, read_frame_of_type, serve};

fn counter_state() -> Value {
    json!({ "$slim": "room/1", "state": { "n": 1 } })
}

#[tokio::test]
async fn a_failing_module_keeps_the_state_until_the_breaker_turns_it_off() {
    let r = room_world(
        "slimm-rooms-breaker",
        "flaky",
        marker_fails_wasm("boom", &counter_state()),
    )
    .await;
    let addr = serve(r.w.state.clone()).await;
    let ava = r.player("ava").await;
    r.join_call(&ava);
    assert_eq!(r.input(&ava, "go").await.1["seq"], 1);
    let mut ws = connect(addr, &ava.ticket).await;

    for _ in 0..4 {
        let (status, answer) = r.input(&ava, "boom").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(answer["applied"], false, "{answer}");
        assert_eq!(answer["error"], "the module tripped");
        assert_eq!(answer["seq"], 1);
        assert_eq!(answer["state"]["n"], 1);
        assert_eq!(r.room(&ava).await["seq"], 1);
    }
    assert!(
        r.w.store
            .installed_module("flaky")
            .await
            .unwrap()
            .unwrap()
            .enabled
    );
    r.input(&ava, "boom").await;
    assert!(
        !r.w.store
            .installed_module("flaky")
            .await
            .unwrap()
            .unwrap()
            .enabled
    );
    let frame = read_frame_of_type(&mut ws, "module.room").await;
    assert_eq!(frame["ended"], "module_off");
    assert_eq!(r.room(&ava).await, Value::Null);
    assert_eq!(r.input(&ava, "go").await.0, StatusCode::CONFLICT);
}

#[tokio::test]
async fn a_success_between_failures_starts_the_count_over() {
    let r = room_world(
        "slimm-rooms-breaker-reset",
        "flaky",
        marker_fails_wasm("boom", &counter_state()),
    )
    .await;
    let (ava, ben) = (r.player("ava").await, r.player("ben").await);
    r.join_call(&ava);
    r.join_call(&ben);
    for _ in 0..4 {
        assert_eq!(r.input(&ava, "boom").await.1["applied"], false);
    }
    assert_eq!(r.input(&ben, "go").await.1["seq"], 1);
    for _ in 0..4 {
        assert_eq!(r.input(&ava, "boom").await.1["applied"], false);
    }
    assert!(
        r.w.store
            .installed_module("flaky")
            .await
            .unwrap()
            .unwrap()
            .enabled
    );
}

#[tokio::test]
async fn a_reply_over_the_cap_or_outside_the_contract_stores_nothing() {
    let huge = json!({ "$slim": "room/1", "state": "x".repeat(17 * 1024) });
    let cases = [
        ("huge", marker_fails_wasm("never", &huge), "bytes"),
        ("rogue", canned_room_wasm(&json!({ "state": 1 })), "room/1"),
    ];
    for (id, wasm, says) in cases {
        let r = room_world(&format!("slimm-rooms-cap-{id}"), id, wasm).await;
        let ava = r.player("ava").await;
        r.join_call(&ava);
        let (status, answer) = r.input(&ava, "go").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(answer["applied"], false, "{answer}");
        assert!(answer["error"].as_str().unwrap().contains(says), "{answer}");
        assert_eq!(answer["seq"], 0);
        assert_eq!(r.room(&ava).await, Value::Null);
    }
}

#[tokio::test]
async fn answers_outside_the_contract_count_toward_the_breaker() {
    let rogue = canned_room_wasm(&json!({ "state": 1 }));
    let r = room_world("slimm-rooms-rogue-breaker", "rogue", rogue).await;
    let ava = r.player("ava").await;
    r.join_call(&ava);
    for _ in 0..5 {
        r.input(&ava, "go").await;
    }
    assert!(
        !r.w.store
            .installed_module("rogue")
            .await
            .unwrap()
            .unwrap()
            .enabled
    );
}

#[tokio::test]
async fn an_input_over_the_cap_is_refused_before_the_module_runs() {
    let r = room_world("slimm-rooms-input-cap", "noughts", noughts_wasm()).await;
    let ava = r.player("ava").await;
    r.join_call(&ava);
    let (status, _) = r.input(&ava, &"4".repeat(1025)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(r.input(&ava, &"4".repeat(1024)).await.0, StatusCode::OK);
}

#[tokio::test]
async fn one_member_is_held_to_the_input_rate() {
    let r = room_world("slimm-rooms-rate", "noughts", noughts_wasm()).await;
    let ava = r.player("ava").await;
    r.join_call(&ava);
    let mut statuses = Vec::new();
    for _ in 0..9 {
        statuses.push(r.input(&ava, "0").await.0);
    }
    assert!(
        statuses[..8].iter().all(|s| *s == StatusCode::OK),
        "{statuses:?}"
    );
    assert_eq!(statuses[8], StatusCode::TOO_MANY_REQUESTS);
}

#[tokio::test]
async fn a_module_without_room_state_approved_keeps_no_room() {
    let r = room_world("slimm-rooms-unapproved", "noughts", noughts_wasm()).await;
    r.w.store
        .set_module_host_capabilities("noughts", &[])
        .await
        .unwrap();
    let ava = r.player("ava").await;
    r.join_call(&ava);
    assert_eq!(r.input(&ava, "0").await.0, StatusCode::NOT_FOUND);
    let (status, body) = r.rooms_in(&ava, r.call).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({ "rooms": [], "call_scenes": [] }));
}

async fn admin_post(r: &RoomWorld, uri: &str) -> StatusCode {
    let request = Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {}", r.w.token))
        .body(Body::empty())
        .unwrap();
    r.w.router.clone().oneshot(request).await.unwrap().status()
}

#[tokio::test]
async fn turning_the_module_off_ends_its_rooms() {
    let r = room_world("slimm-rooms-disable", "noughts", noughts_wasm()).await;
    let admins =
        r.w.store
            .create_role("admins", Permissions::MANAGE_SERVER, false)
            .await
            .unwrap();
    r.w.store.assign_role(r.w.user.id, admins).await.unwrap();
    let addr = serve(r.w.state.clone()).await;
    let ava = r.player("ava").await;
    r.join_call(&ava);
    r.input(&ava, "0").await;
    let mut ws = connect(addr, &ava.ticket).await;
    let status = admin_post(&r, "/space/dock/modules/noughts/disable").await;
    assert_eq!(status, StatusCode::OK);
    let frame = read_frame_of_type(&mut ws, "module.room").await;
    assert_eq!(frame["ended"], "module_off");
    assert_eq!(frame["state"], Value::Null);
    assert_eq!(r.room(&ava).await, Value::Null);
}
