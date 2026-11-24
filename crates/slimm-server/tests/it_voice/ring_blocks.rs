// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A block made after a group DM exists still keeps its ring off the blocker's devices.

use serde_json::json;
use tower::ServiceExt;

use crate::ring_audience::{Person, Rig, rig};
use crate::ring_live_call::group;
use crate::support::app::{json_body, request};
use crate::support::ws::{assert_no_frame_of_type, read_frame_of_type};

async fn block(rig: &Rig, blocker: &Person, target: &Person) {
    let response = rig
        .app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/blocks/{}", target.id),
            Some(&blocker.token),
            None,
        ))
        .await
        .unwrap();
    assert!(response.status().is_success(), "{}", response.status());
}

async fn incoming(rig: &Rig, who: &Person) -> serde_json::Value {
    let response = rig
        .app
        .clone()
        .oneshot(request(
            "GET",
            "/voice/rings/incoming",
            Some(&who.token),
            None,
        ))
        .await
        .unwrap();
    json_body(response).await["rings"].clone()
}

#[tokio::test]
async fn a_group_member_who_blocked_the_caller_is_not_rung_but_the_rest_are() {
    let rig = rig("slimm-ring-block-group").await;
    let alice = rig.person("alice").await;
    let mut bob = rig.person("bob").await;
    let mut cleo = rig.person("cleo").await;
    let channel = group(&rig, &alice, &[&bob, &cleo]).await;
    block(&rig, &bob, &alice).await;
    rig.heartbeat(&channel, &alice).await;

    let started = rig.ring(&channel, &alice).await;

    assert!(started["timeout_ms"].as_i64().unwrap() > 0);
    let frame = read_frame_of_type(&mut cleo.ws, "call.ringing").await;
    assert_eq!(frame["ring_id"], started["ring_id"]);
    assert_no_frame_of_type(&mut bob.ws, "call.ringing").await;
    assert_eq!(incoming(&rig, &bob).await, json!([]));
}

#[tokio::test]
async fn a_group_member_the_caller_blocked_is_not_rung() {
    let rig = rig("slimm-ring-block-by-caller").await;
    let alice = rig.person("alice").await;
    let mut bob = rig.person("bob").await;
    let mut cleo = rig.person("cleo").await;
    let channel = group(&rig, &alice, &[&bob, &cleo]).await;
    block(&rig, &alice, &bob).await;
    rig.heartbeat(&channel, &alice).await;

    rig.ring(&channel, &alice).await;

    read_frame_of_type(&mut cleo.ws, "call.ringing").await;
    assert_no_frame_of_type(&mut bob.ws, "call.ringing").await;
}

#[tokio::test]
async fn a_group_call_where_every_callee_blocked_the_caller_ends_at_once() {
    let rig = rig("slimm-ring-block-all").await;
    let mut alice = rig.person("alice").await;
    let mut bob = rig.person("bob").await;
    let cleo = rig.person("cleo").await;
    let channel = group(&rig, &alice, &[&bob, &cleo]).await;
    block(&rig, &bob, &alice).await;
    block(&rig, &cleo, &alice).await;
    rig.heartbeat(&channel, &alice).await;

    let started = rig.ring(&channel, &alice).await;

    assert_eq!(started["timeout_ms"], 0);
    assert_eq!(started["do_not_disturb"], json!([]));
    let ended = read_frame_of_type(&mut alice.ws, "call.ring_ended").await;
    assert_eq!(ended["ring_id"], started["ring_id"]);
    assert_no_frame_of_type(&mut bob.ws, "call.ringing").await;
    assert_eq!(incoming(&rig, &bob).await, json!([]));
}
