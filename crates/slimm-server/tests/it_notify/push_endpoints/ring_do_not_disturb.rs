// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Do not disturb blocks a ring on every device: no `call.ringing`, no ring push,
//! and the caller is told why when presence would show it, while the callee keeps a missed call.

use axum::http::StatusCode;
use serde_json::{Value, json};
use tower::ServiceExt;

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

async fn calls_in(w: &World, channel: &str, who: &Member) -> Vec<Value> {
    let response = w
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
    json_body(response)
        .await
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| !m["call"].is_null())
        .map(|m| m["call"].clone())
        .collect()
}

/// Bob has no socket open, so presence shows him offline and the caller is not told why.
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
    assert_eq!(started["timeout_ms"], 0);
    w.settle().await;
    assert!(!w.rang_on_the_wire(), "call.ringing was published");
    assert_eq!(w.mock.attempt_count(), before, "a push went out");
    let calls = calls_in(&w, &channel, &bob).await;
    assert_eq!(calls.len(), 1, "the callee keeps a missed call");
    assert_eq!(calls[0]["outcome"], "timed_out");
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
