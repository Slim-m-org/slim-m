// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /sync` names each scope's newest mention of the caller, so a client
//! told to reset keeps the badge of a mention older than the page it refetches.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

use crate::support;
use support::app::register_id_token as register;

async fn mentioned_seqs(app: &axum::Router, token: &str, channels: &[ChannelId]) -> Vec<i64> {
    let scopes: Vec<Value> = channels
        .iter()
        .map(|id| json!({ "channel_id": id.to_string(), "after_seq": 0, "after_op_seq": 0 }))
        .collect();
    let response = app
        .clone()
        .oneshot(
            Request::post("/sync")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({ "scopes": scopes }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 22)
        .await
        .unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    body["scopes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|scope| scope["mentioned_seq"].as_i64().unwrap())
        .collect()
}

async fn send(store: &Store, channel: ChannelId, author: UserId, mentions: &[UserId]) -> MessageId {
    let id = MessageId::generate();
    store
        .send_message(NewMessage::plain(channel, author, id, "hello"))
        .await
        .unwrap();
    store
        .set_message_mentions(id, mentions, None)
        .await
        .unwrap();
    id
}

#[tokio::test]
async fn each_scope_names_the_newest_live_mention_of_the_caller_alone() {
    let (store, _guard) = support::new_store("slimm-sync-mentions").await;
    let app = support::app::router(store.clone());
    let (alice, alice_token) = register(&store, "alice").await;
    let (bob, _) = register(&store, "bob").await;
    let busy = store.create_channel("busy", "text").await.unwrap().id;
    let quiet = store.create_channel("quiet", "text").await.unwrap().id;

    send(&store, busy, bob, &[alice]).await;
    send(&store, busy, bob, &[]).await;
    let newest = send(&store, busy, bob, &[alice]).await;
    send(&store, busy, alice, &[bob]).await;
    send(&store, quiet, bob, &[bob]).await;
    store.delete_message(newest, bob).await.unwrap();

    assert_eq!(
        mentioned_seqs(&app, &alice_token, &[busy, quiet]).await,
        vec![1, 0],
        "the deleted mention and bob's own are not alice's newest"
    );
}
