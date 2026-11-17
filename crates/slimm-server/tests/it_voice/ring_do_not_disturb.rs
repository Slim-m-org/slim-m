// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An offline callee on Do not disturb looks to the caller like anyone offline: rung for the
//! full timeout, then missed.

use std::time::{Duration, Instant};

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::UserId;
use slimm_server::push::PushSender;
use slimm_server::sweep_stale_call_rings_at;
use slimm_server::voice::RING_TIMEOUT;
use tower::ServiceExt;

use crate::ring_audience::rig;
use crate::ring_live_call::{calls_in, set_do_not_disturb};
use crate::support::app::{json_body, request};
use crate::support::wait::wait_until;
use crate::support::ws::{assert_no_frame_of_type, read_frame_of_type};

#[tokio::test]
async fn an_offline_callee_on_do_not_disturb_rings_out_like_anyone_offline() {
    let rig = rig("slimm-ring-dnd-offline").await;
    let mut alice = rig.person("alice").await;
    let bob = rig.person("bob").await;
    let channel = rig.open_dm(&alice, &bob).await;
    set_do_not_disturb(&rig, &bob).await;
    let bob_id = UserId(bob.id.parse().unwrap());
    drop(bob.ws);
    let presence = rig.state.hub.presence();
    wait_until("bob's socket is gone", || !presence.is_connected(bob_id)).await;
    rig.heartbeat(&channel, &alice).await;

    let started = rig.ring(&channel, &alice).await;

    assert_eq!(
        started["timeout_ms"].as_i64(),
        Some(RING_TIMEOUT.as_millis() as i64)
    );
    assert_eq!(started["do_not_disturb"], json!([]));
    assert_no_frame_of_type(&mut alice.ws, "call.ring_ended").await;
    let incoming = rig
        .app
        .clone()
        .oneshot(request(
            "GET",
            "/voice/rings/incoming",
            Some(&bob.token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(incoming.status(), StatusCode::OK);
    assert_eq!(json_body(incoming).await["rings"], json!([]));

    let later = Instant::now() + RING_TIMEOUT + Duration::from_secs(1);
    let push = PushSender::disabled();
    sweep_stale_call_rings_at(&rig.state.voice, &rig.state.hub, &rig.store, &push, later).await;
    let ended = read_frame_of_type(&mut alice.ws, "call.ring_ended").await;
    assert_eq!(ended["ring_id"], started["ring_id"]);
    assert_eq!(ended["outcome"], "timed_out");
    assert_eq!(calls_in(&rig, &channel, &alice).await.len(), 1);
}
