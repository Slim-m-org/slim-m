// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Account-scoped changes reach the account's other open sockets live and
//! nobody else's: "Mark as unread" and a per-channel notification override.

use std::time::Duration;

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::ws::{Client, connect, read_frame_skipping_presence, serve};

use support::app::request_json as request;

async fn seed_everyone(store: &Store) {
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
}

/// One more device for `user`: (rest access token, ws connect ticket).
async fn device(store: &Store, user: UserId) -> (String, String) {
    let tokens = store.open_session(user, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    (tokens.access_token, ticket)
}

/// A new account with its first device: (user id, token, ticket).
async fn account(store: &Store, name: &str) -> (UserId, String, String) {
    let user = store.create_user(name, name).await.unwrap();
    let (token, ticket) = device(store, user.id).await;
    (user.id, token, ticket)
}

async fn frame_within(ws: &mut Client, within: Duration) -> Option<Value> {
    tokio::time::timeout(within, read_frame_skipping_presence(ws))
        .await
        .ok()
}

/// Reads frames until one of `kind` arrives; `None` once the socket goes quiet.
async fn frame_of_kind(ws: &mut Client, kind: &str) -> Option<Value> {
    while let Some(frame) = frame_within(ws, Duration::from_millis(500)).await {
        if frame["type"] == kind {
            return Some(frame);
        }
    }
    None
}

async fn send(state: &AppState, token: &str, channel: ChannelId) -> Value {
    let response = http::router(state.clone())
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages"),
            token,
            json!({ "id": Uuid::now_v7().to_string(), "content": "hello" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn marking_unread_reaches_the_other_device_once_and_nobody_else() {
    let (store, _guard) = support::new_store("slimm-account-sync-events").await;
    seed_everyone(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());
    let (alice, phone_token, _ticket) = account(&store, "alice").await;
    let (_desktop_token, desktop_ticket) = device(&store, alice).await;
    let (_bob, _bob_token, bob_ticket) = account(&store, "bob").await;
    let addr = serve(state.clone()).await;
    let mut desktop = connect(addr, &desktop_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let uri = format!("/channels/{}/unread", channel.id);
    let first = http::router(state.clone())
        .oneshot(request("PUT", &uri, &phone_token, json!({})))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);

    let frame = frame_of_kind(&mut desktop, "read_state.changed")
        .await
        .expect("the other device must hear about the unread mark");
    assert_eq!(frame["channel_id"], channel.id.to_string());
    assert_eq!(frame["manually_unread"], true);

    let again = http::router(state.clone())
        .oneshot(request("PUT", &uri, &phone_token, json!({})))
        .await
        .unwrap();
    assert_eq!(again.status(), StatusCode::OK);
    assert!(
        frame_of_kind(&mut desktop, "read_state.changed")
            .await
            .is_none(),
        "an unchanged mark publishes nothing"
    );
    assert!(
        frame_within(&mut bob_ws, Duration::from_millis(300))
            .await
            .is_none()
    );
}

#[tokio::test]
async fn a_read_frame_says_the_manual_mark_is_cleared() {
    let (store, _guard) = support::new_store("slimm-account-sync-events").await;
    seed_everyone(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());
    let (alice, phone_token, _ticket) = account(&store, "alice").await;
    let (_desktop_token, desktop_ticket) = device(&store, alice).await;
    let addr = serve(state.clone()).await;
    let mut desktop = connect(addr, &desktop_ticket).await;
    send(&state, &phone_token, channel.id).await;
    let _own_send = frame_of_kind(&mut desktop, "read_state.changed").await;

    http::router(state.clone())
        .oneshot(request(
            "PUT",
            &format!("/channels/{}/unread", channel.id),
            &phone_token,
            json!({}),
        ))
        .await
        .unwrap();
    let marked = frame_of_kind(&mut desktop, "read_state.changed")
        .await
        .unwrap();
    assert_eq!(marked["manually_unread"], true);
    assert_eq!(marked["last_read_seq"], 1);

    http::router(state.clone())
        .oneshot(request(
            "PUT",
            &format!("/channels/{}/read", channel.id),
            &phone_token,
            json!({ "seq": 1 }),
        ))
        .await
        .unwrap();
    let cleared = frame_of_kind(&mut desktop, "read_state.changed")
        .await
        .unwrap();
    assert_eq!(cleared["manually_unread"], false);
}

#[tokio::test]
async fn a_channel_override_reaches_the_other_device_and_nobody_else() {
    let (store, _guard) = support::new_store("slimm-account-sync-events").await;
    seed_everyone(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());
    let (alice, phone_token, _ticket) = account(&store, "alice").await;
    let (_desktop_token, desktop_ticket) = device(&store, alice).await;
    let (_bob, _bob_token, bob_ticket) = account(&store, "bob").await;
    let addr = serve(state.clone()).await;
    let mut desktop = connect(addr, &desktop_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let uri = format!("/notification-preferences/channels/{}", channel.id);
    let set = http::router(state.clone())
        .oneshot(request(
            "PUT",
            &uri,
            &phone_token,
            json!({ "preference": "mentions" }),
        ))
        .await
        .unwrap();
    assert_eq!(set.status(), StatusCode::OK);
    let frame = frame_of_kind(&mut desktop, "notification_override.changed")
        .await
        .expect("the other device must hear about the override");
    assert_eq!(frame["channel_id"], channel.id.to_string());
    assert_eq!(frame["preference"], "mentions");

    let same = http::router(state.clone())
        .oneshot(request(
            "PUT",
            &uri,
            &phone_token,
            json!({ "preference": "mentions" }),
        ))
        .await
        .unwrap();
    assert_eq!(same.status(), StatusCode::OK);
    assert!(
        frame_of_kind(&mut desktop, "notification_override.changed")
            .await
            .is_none(),
        "setting the same override again publishes nothing"
    );

    let cleared = http::router(state.clone())
        .oneshot(request("DELETE", &uri, &phone_token, json!({})))
        .await
        .unwrap();
    assert_eq!(cleared.status(), StatusCode::NO_CONTENT);
    let frame = frame_of_kind(&mut desktop, "notification_override.changed")
        .await
        .expect("clearing is announced too");
    assert!(frame["preference"].is_null());
    assert!(
        frame_within(&mut bob_ws, Duration::from_millis(300))
            .await
            .is_none()
    );
}
