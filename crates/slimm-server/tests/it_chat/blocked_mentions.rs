// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member who blocked an author never gets a mention from them: not for a
//! written @name, not for a reply ping, and not through `@everyone`.

use axum::Router;
use serde_json::{Value, json};
use slimm_server::ids::UserId;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use support::overwrite_harness::{
    app, general_channel_id, json_body, new_store, register, request,
};

struct World {
    app: Router,
    store: Store,
    channel: String,
    alice: (String, UserId),
    bob: (String, UserId),
    carol: (String, UserId),
    _guard: support::TestDbGuard,
}

async fn world(name: &str) -> World {
    let (store, guard) = new_store(name).await;
    let mut people = Vec::new();
    for who in ["alice", "bob", "carol"] {
        let (token, id) = register(&store, who).await;
        people.push((token, UserId(id.parse().unwrap())));
    }
    let channel = general_channel_id(&store).await;
    let mut people = people.into_iter();
    World {
        app: app(store.clone()),
        store,
        channel,
        alice: people.next().unwrap(),
        bob: people.next().unwrap(),
        carol: people.next().unwrap(),
        _guard: guard,
    }
}

async fn send(w: &World, token: &str, body: Value) -> String {
    let sent = json_body(
        w.app
            .clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{}/messages", w.channel),
                Some(token),
                Some(body),
            ))
            .await
            .unwrap(),
    )
    .await;
    sent["id"].as_str().unwrap().to_owned()
}

async fn mentions_me(w: &World, token: &str, id: &str) -> bool {
    let listed = json_body(
        w.app
            .clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{}/messages", w.channel),
                Some(token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    listed
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == id)
        .unwrap_or_else(|| panic!("{id} not listed"))["mentions_me"]
        .as_bool()
        .unwrap()
}

fn text(content: &str) -> Value {
    json!({ "id": Uuid::now_v7().to_string(), "content": content })
}

#[tokio::test]
async fn a_written_mention_from_a_blocked_author_does_not_count() {
    let w = world("slimm-blocked-mention-name").await;
    w.store.block_user(w.alice.1, w.bob.1).await.unwrap();
    let id = send(&w, &w.bob.0, text("hey @alice and @carol")).await;
    assert!(!mentions_me(&w, &w.alice.0, &id).await);
    assert!(mentions_me(&w, &w.carol.0, &id).await, "others still hear");
}

#[tokio::test]
async fn a_mass_mention_from_a_blocked_author_skips_the_blocker() {
    let w = world("slimm-blocked-mention-everyone").await;
    w.store.block_user(w.bob.1, w.alice.1).await.unwrap();
    let id = send(&w, &w.alice.0, text("@everyone hello")).await;
    assert!(!mentions_me(&w, &w.bob.0, &id).await);
    assert!(mentions_me(&w, &w.carol.0, &id).await);
}

#[tokio::test]
async fn a_reply_ping_from_a_blocked_author_does_not_count() {
    let w = world("slimm-blocked-mention-reply").await;
    let original = send(&w, &w.alice.0, text("lunch?")).await;
    w.store.block_user(w.alice.1, w.bob.1).await.unwrap();
    let reply = json!({
        "id": Uuid::now_v7().to_string(), "content": "yes",
        "reply_to_id": original, "mention_reply": true,
    });
    let id = send(&w, &w.bob.0, reply).await;
    assert!(!mentions_me(&w, &w.alice.0, &id).await);
}

#[tokio::test]
async fn the_blocked_author_still_mentions_whoever_blocked_nobody() {
    let w = world("slimm-blocked-mention-reverse").await;
    w.store.block_user(w.alice.1, w.bob.1).await.unwrap();
    let id = send(&w, &w.alice.0, text("hi @bob")).await;
    assert!(mentions_me(&w, &w.bob.0, &id).await);
}
