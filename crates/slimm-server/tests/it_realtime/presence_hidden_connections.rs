// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member who appears offline sends no presence frame when they connect, disconnect or open a
//! second kind of device; only switching visibility is announced.

use std::time::Duration;

use serde_json::Value;
use slimm_server::hub::Hub;
use slimm_server::presence::Visibility;

use crate::support;
use support::ws::{Client, connect, serve, user_ticket, wait_for_frame};

const QUIET: Duration = Duration::from_millis(400);

async fn presence_for(ws: &mut Client, user: &str, window: Duration) -> Option<Value> {
    loop {
        let frame = wait_for_frame(ws, "presence.changed", window).await?;
        if frame["user_id"] == user {
            return Some(frame);
        }
    }
}

#[tokio::test]
async fn a_hidden_members_connect_and_disconnect_send_no_frame() {
    let (store, _guard) = support::new_store("slimm-presence-hidden-conn").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (_, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (_, bob_ticket, bob_id) = user_ticket(&store, "bob").await;
    let (alice, bob) = (alice_id.to_string(), bob_id.to_string());
    store
        .set_presence_visibility(alice_id, Visibility::Hidden)
        .await
        .unwrap();
    let addr = serve(state).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    assert!(
        presence_for(&mut bob_ws, &bob, Duration::from_secs(2))
            .await
            .is_some()
    );

    let mut alice_ws = connect(addr, &alice_ticket).await;
    let own = presence_for(&mut alice_ws, &alice, Duration::from_secs(2)).await;
    assert_eq!(own.expect("alice sees herself")["status"], "online");
    assert!(
        presence_for(&mut bob_ws, &alice, QUIET).await.is_none(),
        "a hidden member's connect must not reach other members"
    );

    drop(alice_ws);
    assert!(
        presence_for(&mut bob_ws, &alice, QUIET).await.is_none(),
        "a hidden member's disconnect must not reach other members"
    );
}

#[tokio::test]
async fn going_hidden_is_still_announced_once() {
    let (store, _guard) = support::new_store("slimm-presence-hidden-switch").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (alice_access, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (_, bob_ticket, _) = user_ticket(&store, "bob").await;
    let alice = alice_id.to_string();
    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let _alice_ws = connect(addr, &alice_ticket).await;
    let online = presence_for(&mut bob_ws, &alice, Duration::from_secs(2)).await;
    assert_eq!(online.expect("online frame")["status"], "online");

    let response = tower::ServiceExt::oneshot(
        slimm_server::http::router(state),
        axum::http::Request::builder()
            .method("PATCH")
            .uri("/presence")
            .header("authorization", format!("Bearer {alice_access}"))
            .header("content-type", "application/json")
            .body(axum::body::Body::from(r#"{"visibility":"hidden"}"#))
            .unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(response.status(), 200);

    let gone = presence_for(&mut bob_ws, &alice, Duration::from_secs(2)).await;
    assert_eq!(
        gone.expect("the switch itself is announced")["status"],
        "offline"
    );
}
