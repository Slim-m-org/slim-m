// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A session that reconnects after losing its socket is online again to
//! everyone, through both the WebSocket broadcast and the REST lookup.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use tower::ServiceExt;

mod support;

use support::ws::{Client, connect, read_frame, serve, user_ticket};

/// Reads frames until one is a `presence.changed` for `user_id`, ignoring any
/// other event kind. Bounded so a missing event fails the test instead of
/// hanging it.
async fn next_presence_for(ws: &mut Client, user_id: &str) -> Value {
    let outcome = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let frame = read_frame(ws).await;
            if frame["type"] == "presence.changed" && frame["user_id"] == user_id {
                return frame;
            }
        }
    })
    .await;
    outcome.unwrap_or_else(|_| panic!("no presence.changed for {user_id} arrived in time"))
}

fn get_request(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn presence_status(state: &AppState, token: &str, target_id: &str) -> String {
    let uri = format!("/presence?ids={target_id}");
    let response = http::router(state.clone())
        .oneshot(get_request(&uri, token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let entries: Vec<Value> = serde_json::from_slice(&body).unwrap();
    entries[0]["status"].as_str().unwrap().to_owned()
}

/// The server holds no presence past a socket's life, so a client that lost
/// its socket and reconnects reads online again with nothing re-announced. A
/// client that never notices the loss stays offline to everyone instead.
#[tokio::test]
async fn a_reconnecting_session_is_online_again_without_re_announcing() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (alice_access, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (bob_access, bob_ticket, bob_id) = user_ticket(&store, "bob").await;
    let alice_id_str = alice_id.to_string();

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let _ = next_presence_for(&mut bob_ws, &bob_id.to_string()).await;

    let alice_ws = connect(addr, &alice_ticket).await;
    assert_eq!(
        next_presence_for(&mut bob_ws, &alice_id_str).await["status"],
        "online"
    );
    drop(alice_ws);
    assert_eq!(
        next_presence_for(&mut bob_ws, &alice_id_str).await["status"],
        "offline"
    );

    let ctx = store.authenticate(&alice_access).await.unwrap().unwrap();
    let (fresh_ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    let _alice_again = connect(addr, &fresh_ticket).await;
    assert_eq!(
        next_presence_for(&mut bob_ws, &alice_id_str).await["status"],
        "online"
    );
    assert_eq!(
        presence_status(&state, &bob_access, &alice_id_str).await,
        "online"
    );
}
