// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /sync` names a scope's newest mention of the caller where the client
//! needs it: on a scope told to reset, so it keeps the badge of a mention older
//! than the page it refetches, and on one whose cursor asks, so a mention
//! cursor left on a message it never held can heal. Every other scope skips
//! the read, which scans all of the caller's mentions.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

use crate::support;
use support::app::register_id_token as register;

/// The `mentioned_seq` of each scope `cursors` asked about, null where the response has none.
async fn mentioned_seqs(app: &axum::Router, token: &str, cursors: Vec<Value>) -> Vec<Value> {
    let response = app
        .clone()
        .oneshot(
            Request::post("/sync")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({ "scopes": cursors }).to_string()))
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
        .map(|scope| scope["mentioned_seq"].clone())
        .collect()
}

fn asking(channel: ChannelId) -> Value {
    json!({ "channel_id": channel.to_string(), "after_seq": 0, "after_op_seq": 0, "check_mention": true })
}

async fn send(store: &Store, channel: ChannelId, author: UserId, mentions: &[UserId]) -> MessageId {
    let id = MessageId::generate();
    store
        .send_message(NewMessage::plain(channel, author, id, "hello"))
        .await
        .unwrap();
    store
        .set_message_mentions(id, mentions, None, &[])
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
        mentioned_seqs(&app, &alice_token, vec![asking(busy), asking(quiet)]).await,
        vec![json!(1), json!(0)],
        "the deleted mention and bob's own are not alice's newest"
    );
}

#[tokio::test]
async fn only_a_scope_that_resets_or_asks_reads_its_mentions() {
    let (store, _guard) = support::new_store("slimm-sync-mentions-asked").await;
    let app = support::app::router(store.clone());
    let (alice, alice_token) = register(&store, "alice").await;
    let (bob, _) = register(&store, "bob").await;
    let channels = [
        store.create_channel("caught-up", "text").await.unwrap().id,
        store.create_channel("restored", "text").await.unwrap().id,
        store.create_channel("asked", "text").await.unwrap().id,
    ];
    for channel in channels {
        send(&store, channel, bob, &[alice]).await;
    }
    let [caught_up, restored, asked] = channels.map(|id| id.to_string());

    assert_eq!(
        mentioned_seqs(
            &app,
            &alice_token,
            vec![
                json!({ "channel_id": caught_up, "after_seq": 0, "after_op_seq": 0 }),
                // A cursor past the head is a restored server's, and resets.
                json!({ "channel_id": restored, "after_seq": 9, "after_op_seq": 0 }),
                json!({ "channel_id": asked, "after_seq": 0, "check_mention": true }),
            ],
        )
        .await,
        vec![Value::Null, json!(1), json!(1)],
        "a scope that neither resets nor asks carries no marker"
    );
}
