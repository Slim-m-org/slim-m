// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Do not disturb blocks a ring on every device: no `call.ringing`, no ring push,
//! and the caller is told why when presence would show it, while the callee keeps a missed call.

use axum::http::StatusCode;
use serde_json::{Value, json};
use tower::ServiceExt;

use slimm_server::voice::RING_TIMEOUT;

use crate::push_endpoints::harness::{json_body, request};
use crate::push_endpoints::missed_call::{join, open_dm};
use crate::push_endpoints::ring_refusals::{Member, World, world};

async fn set_do_not_disturb(w: &World, who: &Member) {
    let response = w
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

async fn ring(w: &World, channel: &str, who: &Member) -> Value {
    join(&w.app, channel, &who.token).await;
    let response = w
        .app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/voice/ring"),
            Some(&who.token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await
}

/// Bob has no socket open, so presence shows him offline: the caller waits out the
/// normal ring rather than learning he is on Do not disturb, and nothing reaches him.
/// The missed call after the timeout is pinned in it_voice::ring_do_not_disturb.
#[tokio::test]
async fn a_callee_on_do_not_disturb_is_not_rung_on_any_device() {
    let mut w = world().await;
    let alice = w.member("alice").await;
    let bob = w.member("bob").await;
    let channel = open_dm(&w.app, &alice.token, &bob.id.to_string()).await;
    set_do_not_disturb(&w, &bob).await;
    w.settle().await;
    let before = w.mock.attempt_count();

    let started = ring(&w, &channel, &alice).await;

    assert_eq!(started["do_not_disturb"], json!([]));
    assert_eq!(
        started["timeout_ms"],
        RING_TIMEOUT.as_millis() as i64,
        "an offline callee on Do not disturb must look like an ordinary unanswered ring"
    );
    w.settle().await;
    assert!(!w.rang_on_the_wire(), "call.ringing was published");
    assert_eq!(w.mock.attempt_count(), before, "a push went out");
}

#[tokio::test]
async fn a_group_rings_everyone_but_the_member_on_do_not_disturb() {
    let mut w = world().await;
    let alice = w.member("alice").await;
    let bob = w.member("bob").await;
    let cleo = w.member("cleo").await;
    let response = w
        .app
        .clone()
        .oneshot(request(
            "POST",
            "/dms/groups",
            Some(&alice.token),
            Some(json!({
                "id": uuid::Uuid::now_v7().to_string(),
                "user_ids": [bob.id.to_string(), cleo.id.to_string()],
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let channel = json_body(response).await["channel_id"]
        .as_str()
        .unwrap()
        .to_owned();
    set_do_not_disturb(&w, &bob).await;

    let started = ring(&w, &channel, &alice).await;

    assert_eq!(
        started["do_not_disturb"],
        json!([]),
        "bob has no socket, so reads as offline"
    );
    assert!(started["timeout_ms"].as_i64().unwrap() > 0);
    assert!(w.rang_on_the_wire(), "cleo is still rung");
}
