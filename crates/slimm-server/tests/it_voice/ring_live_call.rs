// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pressing Call on a call that is already live joins it: nobody is rung and no missed call is
//! written. A device that dropped out without leaving is not taken for someone still there.

use std::time::{Duration, Instant};

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::push::PushSender;
use slimm_server::sweep_stale_call_rings_at;
use slimm_server::voice::RING_TIMEOUT;
use tower::ServiceExt;

use crate::ring_audience::{Person, Rig, rig};
use crate::support::app::{json_body, request};
use crate::support::wait::wait_until;
use crate::support::ws::{assert_no_frame_of_type, read_frame_of_type};

async fn send(rig: &Rig, method: &str, uri: &str, who: &Person, body: Value) -> Value {
    let response = rig
        .app
        .clone()
        .oneshot(request(method, uri, Some(&who.token), Some(body)))
        .await
        .unwrap();
    assert!(response.status().is_success(), "{}", response.status());
    json_body(response).await
}

async fn group(rig: &Rig, owner: &Person, others: &[&Person]) -> String {
    let user_ids: Vec<&str> = others.iter().map(|p| p.id.as_str()).collect();
    let body = json!({ "id": uuid::Uuid::now_v7().to_string(), "user_ids": user_ids });
    send(rig, "POST", "/dms/groups", owner, body).await["channel_id"]
        .as_str()
        .unwrap()
        .to_owned()
}

async fn set_do_not_disturb(rig: &Rig, who: &Person) {
    let response = rig
        .app
        .clone()
        .oneshot(request(
            "PATCH",
            "/presence",
            Some(&who.token),
            Some(json!({ "visibility": "dnd" })),
        ))
        .await
        .unwrap();
    assert!(response.status().is_success(), "{}", response.status());
}

async fn calls_in(rig: &Rig, channel: &str, who: &Person) -> Vec<Value> {
    let response = rig
        .app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel}/messages"),
            Some(&who.token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response)
        .await
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| !m["call"].is_null())
        .map(|m| m["call"].clone())
        .collect()
}

fn ids(channel: &str, who: &Person) -> (ChannelId, UserId) {
    (
        ChannelId(channel.parse().unwrap()),
        UserId(who.id.parse().unwrap()),
    )
}

async fn assert_ended_at_once_as_answered(started: &Value, caller: &mut Person) {
    assert_eq!(started["timeout_ms"], 0);
    assert_eq!(started["do_not_disturb"], json!([]));
    let ended = read_frame_of_type(&mut caller.ws, "call.ring_ended").await;
    assert_eq!(ended["ring_id"], started["ring_id"]);
    assert_eq!(ended["outcome"], "answered");
}

#[tokio::test]
async fn pressing_call_on_a_live_group_call_joins_it_without_ringing_the_rest() {
    let rig = rig("slimm-ring-live-group").await;
    let mut alice = rig.person("alice").await;
    let bob = rig.person("bob").await;
    let mut cleo = rig.person("cleo").await;
    let channel = group(&rig, &alice, &[&bob, &cleo]).await;
    rig.heartbeat(&channel, &bob).await;
    rig.heartbeat(&channel, &alice).await;

    let started = rig.ring(&channel, &alice).await;

    assert_ended_at_once_as_answered(&started, &mut alice).await;
    assert_no_frame_of_type(&mut cleo.ws, "call.ringing").await;
    assert!(calls_in(&rig, &channel, &cleo).await.is_empty());
}

#[tokio::test]
async fn a_live_group_call_with_everyone_else_on_do_not_disturb_is_joined_not_missed() {
    let rig = rig("slimm-ring-live-group-dnd").await;
    let mut alice = rig.person("alice").await;
    let bob = rig.person("bob").await;
    let cleo = rig.person("cleo").await;
    let channel = group(&rig, &alice, &[&bob, &cleo]).await;
    set_do_not_disturb(&rig, &cleo).await;
    rig.heartbeat(&channel, &bob).await;
    rig.heartbeat(&channel, &alice).await;

    let started = rig.ring(&channel, &alice).await;

    assert_ended_at_once_as_answered(&started, &mut alice).await;
    assert!(
        calls_in(&rig, &channel, &cleo).await.is_empty(),
        "a missed call was written into a group whose call is live"
    );
}

#[tokio::test]
async fn a_partial_ring_that_times_out_on_a_live_call_is_not_a_missed_call() {
    let rig = rig("slimm-ring-live-partial").await;
    let mut alice = rig.person("alice").await;
    let bob = rig.person("bob").await;
    let cleo = rig.person("cleo").await;
    let channel = group(&rig, &alice, &[&bob, &cleo]).await;
    let (channel_id, bob_id) = ids(&channel, &bob);
    let voice = &rig.state.voice;
    // Bob's last beat is late, so he is rung along with cleo, and only his next keepalive lands.
    voice.record_heartbeat_at_for_test(
        bob_id,
        channel_id,
        Instant::now() - Duration::from_secs(25),
    );
    rig.heartbeat(&channel, &alice).await;
    let started = rig.ring(&channel, &alice).await;
    assert!(started["timeout_ms"].as_i64().unwrap() > 0);

    let later = Instant::now() + RING_TIMEOUT + Duration::from_secs(1);
    voice.record_heartbeat_at_for_test(bob_id, channel_id, later);
    let push = PushSender::disabled();
    sweep_stale_call_rings_at(voice, &rig.state.hub, &rig.store, &push, later).await;

    let ended = read_frame_of_type(&mut alice.ws, "call.ring_ended").await;
    assert_eq!(ended["ring_id"], started["ring_id"]);
    assert_eq!(ended["outcome"], "answered");
    assert!(calls_in(&rig, &channel, &cleo).await.is_empty());
}

#[tokio::test]
async fn a_callee_whose_device_dropped_without_leaving_is_rung() {
    let rig = rig("slimm-ring-live-dropped").await;
    let alice = rig.person("alice").await;
    let mut bob = rig.person("bob").await;
    let channel = rig.open_dm(&alice, &bob).await;
    let (channel_id, bob_id) = ids(&channel, &bob);
    rig.heartbeat(&channel, &bob).await;
    let live_state = rig.state.voice.live_state();
    live_state.mark_joined(channel_id, bob_id, "PA_bob");
    live_state.mark_left(channel_id, bob_id, "PA_bob");
    rig.heartbeat(&channel, &alice).await;

    let started = rig.ring(&channel, &alice).await;

    assert!(started["timeout_ms"].as_i64().unwrap() > 0);
    let frame = read_frame_of_type(&mut bob.ws, "call.ringing").await;
    assert_eq!(frame["ring_id"], started["ring_id"]);
}

#[tokio::test]
async fn a_callee_whose_heartbeat_went_quiet_is_rung() {
    let rig = rig("slimm-ring-live-quiet").await;
    let alice = rig.person("alice").await;
    let mut bob = rig.person("bob").await;
    let channel = rig.open_dm(&alice, &bob).await;
    let (channel_id, bob_id) = ids(&channel, &bob);
    rig.state.voice.record_heartbeat_at_for_test(
        bob_id,
        channel_id,
        Instant::now() - Duration::from_secs(25),
    );
    rig.heartbeat(&channel, &alice).await;

    let started = rig.ring(&channel, &alice).await;

    assert!(started["timeout_ms"].as_i64().unwrap() > 0);
    read_frame_of_type(&mut bob.ws, "call.ringing").await;
}

#[tokio::test]
async fn a_connected_callee_on_do_not_disturb_is_reported() {
    let rig = rig("slimm-ring-live-dnd-shown").await;
    let alice = rig.person("alice").await;
    let bob = rig.person("bob").await;
    let channel = rig.open_dm(&alice, &bob).await;
    let (_, bob_id) = ids(&channel, &bob);
    let presence = rig.state.hub.presence();
    wait_until("bob's socket counts as connected", || {
        presence.is_connected(bob_id)
    })
    .await;
    set_do_not_disturb(&rig, &bob).await;
    rig.heartbeat(&channel, &alice).await;

    let started = rig.ring(&channel, &alice).await;

    assert_eq!(started["do_not_disturb"], json!([bob.id]));
}

#[tokio::test]
async fn a_new_ring_that_ends_at_once_ends_the_one_still_ringing() {
    let rig = rig("slimm-ring-live-replaced").await;
    let alice = rig.person("alice").await;
    let mut bob = rig.person("bob").await;
    let channel = rig.open_dm(&alice, &bob).await;
    rig.heartbeat(&channel, &alice).await;
    let first = rig.ring(&channel, &alice).await;
    read_frame_of_type(&mut bob.ws, "call.ringing").await;
    set_do_not_disturb(&rig, &bob).await;

    let second = rig.ring(&channel, &alice).await;
    assert_eq!(second["timeout_ms"], 0);
    let ended = read_frame_of_type(&mut bob.ws, "call.ring_ended").await;
    assert_eq!(
        ended["ring_id"], first["ring_id"],
        "the first ring kept ringing"
    );

    let response = rig
        .app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{channel}/voice/heartbeat"),
            Some(&alice.token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert_eq!(
        calls_in(&rig, &channel, &bob).await.len(),
        1,
        "one call attempt left more than one missed call"
    );
}
