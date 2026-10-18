// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Slow mode cannot be skipped by deleting the last message or by sending in
//! parallel; the window is measured and checked inside the send transaction.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token as register, request};

fn send(uri: &str, token: &str, content: &str) -> Request<Body> {
    request(
        "POST",
        uri,
        Some(token),
        Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
    )
}

async fn setup() -> (
    Store,
    support::TestDbGuard,
    Router,
    String,
    slimm_server::store::Channel,
) {
    let (store, guard) = support::new_store("slimm-slow-mode-bypass").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    store
        .update_channel_slow_mode(channel.id, 60)
        .await
        .unwrap();
    let app = app(store.clone());
    let _admin = register(&store, "admin").await;
    let token = register(&store, "bob").await;
    (store, guard, app, token, channel)
}

#[tokio::test]
async fn deleting_the_last_message_does_not_reset_slow_mode() {
    let (_store, _guard, app, token, channel) = setup().await;
    let uri = format!("/channels/{}/messages", channel.id);
    let first = app
        .clone()
        .oneshot(send(&uri, &token, "one"))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    let m1 = json_body(first).await;
    let del = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("{uri}/{}", m1["id"].as_str().unwrap()),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert!(del.status().is_success(), "delete: {}", del.status());
    let second = app
        .clone()
        .oneshot(send(&uri, &token, "two"))
        .await
        .unwrap();
    assert_eq!(
        second.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "send right after deleting own last message"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn parallel_sends_pass_slow_mode_only_once() {
    let (_store, _guard, app, token, channel) = setup().await;
    let uri = format!("/channels/{}/messages", channel.id);
    let mut handles = Vec::new();
    for i in 0..8 {
        let app = app.clone();
        let uri = uri.clone();
        let token = token.clone();
        handles.push(tokio::spawn(async move {
            app.oneshot(send(&uri, &token, &format!("p{i}")))
                .await
                .unwrap()
                .status()
        }));
    }
    let mut ok = 0;
    for h in handles {
        if h.await.unwrap() == StatusCode::OK {
            ok += 1;
        }
    }
    assert_eq!(
        ok, 1,
        "exactly one of 8 parallel sends may pass a 60s slow mode"
    );
}
