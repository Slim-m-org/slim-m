// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! End-to-end coverage for the `ProfileChanged` event: the fix for the
//! recorded debt that a display name change never reached a live client, so
//! a message row already cached locally showed the old name until the whole
//! cache was wiped. See `live_role_events.rs` for the sibling deployment-wide
//! events this one is shaped after.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::http::{self};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

mod support;

use support::ws::{connect, read_frame_skipping_presence_timed, serve, user_ticket};

fn req(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(value) => {
            builder = builder.header("content-type", "application/json");
            builder.body(Body::from(value.to_string())).unwrap()
        }
        None => builder.body(Body::empty()).unwrap(),
    }
}

/// A rename reaches every live connection, not just the caller's own, and
/// carries the id alone: the name lives in exactly one place and a receiver
/// re-asks for it rather than trusting a value riding this frame.
#[tokio::test]
async fn profile_changed_reaches_everyone_without_leaking_the_new_name() {
    let (store, _guard) = support::new_store("slimm-live-profile-events-test").await;
    store
        .create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let state = support::app::state(store.clone());

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    // An uninvolved bystander: a display name is already public on every profile response.
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let response = http::router(state.clone())
        .oneshot(req(
            "PATCH",
            "/me",
            &alice_access,
            Some(json!({ "display_name": "Alice In Wonderland" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    for ws in [&mut alice_ws, &mut bob_ws] {
        let frame = read_frame_skipping_presence_timed(ws).await;
        assert_eq!(frame["type"], "profile.changed");
        assert_eq!(frame["user_id"], alice.to_string());
        assert!(
            frame.get("display_name").is_none(),
            "the new name must never ride this frame, only the id: {frame}"
        );
    }
}
