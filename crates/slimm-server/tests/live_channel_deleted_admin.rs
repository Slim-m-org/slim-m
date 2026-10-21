// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `channel.deleted` reaches an admin who sees a private channel only through
//! ADMINISTRATOR. The owner's sidebar kept a deleted private voice channel, so
//! this pins the server side of that as sound.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::http::{self};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
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

/// Grants ADMINISTRATOR to a user so every test below can create, rename, and
/// delete channels and set or clear overwrites without wiring up every bit
/// each verb happens to need.
async fn make_admin(store: &Store, user_id: slimm_server::ids::UserId) {
    let role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    store.assign_role(user_id, role).await.unwrap();
}

#[tokio::test]
async fn channel_deleted_reaches_an_admin_who_sees_a_private_channel_by_administrator() {
    let (store, _guard) = support::new_store("slimm-live-channel-events-test").await;
    let everyone = store
        .create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let _keep = store.create_channel("keep", "text").await.unwrap();
    let doomed = store
        .create_channel("private-voice", "voice")
        .await
        .unwrap();
    store
        .set_role_overwrite(
            doomed.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let state = support::app::state(store.clone());

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    make_admin(&store, alice).await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let uri = format!("/channels/{}", doomed.id);
    let response = http::router(state.clone())
        .oneshot(req("DELETE", &uri, &alice_access, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let frame = read_frame_skipping_presence_timed(&mut alice_ws).await;
    assert_eq!(frame["type"], "channel.deleted");
    assert_eq!(frame["channel_id"], doomed.id.to_string());

    let bob_next = tokio::time::timeout(
        Duration::from_millis(300),
        read_frame_skipping_presence_timed(&mut bob_ws),
    )
    .await;
    assert!(bob_next.is_err(), "bob never saw the private channel");
}
