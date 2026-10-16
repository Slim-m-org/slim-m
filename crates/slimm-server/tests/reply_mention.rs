// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A reply can ping the author it replies to, Discord style (backlog #249):
//! with mention_reply the author sees mentions_me, without it the reply stays
//! quiet, a reply to yourself never pings, and an edit keeps the ping.

use axum::Router;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

mod support;
use support::overwrite_harness::{app, json_body, new_store, register, request};

struct World {
    app: Router,
    channel: String,
    alice: String,
    bob: String,
    _guard: support::TestDbGuard,
}

async fn world(name: &str) -> World {
    let (store, guard) = new_store(name).await;
    let (alice, _) = register(&store, "alice").await;
    let (bob, _) = register(&store, "bob").await;
    store
        .create_role(
            "chatters",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            false,
        )
        .await
        .ok();
    let channel = support::overwrite_harness::general_channel_id(&store).await;
    World {
        app: app(store),
        channel,
        alice,
        bob,
        _guard: guard,
    }
}

async fn send(w: &World, token: &str, body: Value) -> Value {
    json_body(
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
    .await
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

fn reply(text: &str, to: &str, ping: bool) -> Value {
    json!({ "id": Uuid::now_v7().to_string(), "content": text, "reply_to_id": to, "mention_reply": ping })
}

#[tokio::test]
async fn a_reply_with_mention_reply_pings_the_author_and_one_without_does_not() {
    let w = world("slimm-reply-mention").await;
    let original = send(
        &w,
        &w.bob,
        json!({ "id": Uuid::now_v7().to_string(), "content": "lunch?" }),
    )
    .await;
    let to = original["id"].as_str().unwrap();

    let pinged = send(&w, &w.alice, reply("yes", to, true)).await;
    let quiet = send(&w, &w.alice, reply("also yes", to, false)).await;

    assert!(mentions_me(&w, &w.bob, pinged["id"].as_str().unwrap()).await);
    assert!(!mentions_me(&w, &w.bob, quiet["id"].as_str().unwrap()).await);
}

#[tokio::test]
async fn replying_to_yourself_never_pings() {
    let w = world("slimm-reply-mention-self").await;
    let original = send(
        &w,
        &w.alice,
        json!({ "id": Uuid::now_v7().to_string(), "content": "note" }),
    )
    .await;
    let mine = send(
        &w,
        &w.alice,
        reply("more", original["id"].as_str().unwrap(), true),
    )
    .await;
    assert!(!mentions_me(&w, &w.alice, mine["id"].as_str().unwrap()).await);
}

#[tokio::test]
async fn an_edit_keeps_the_reply_ping() {
    let w = world("slimm-reply-mention-edit").await;
    let original = send(
        &w,
        &w.bob,
        json!({ "id": Uuid::now_v7().to_string(), "content": "lunch?" }),
    )
    .await;
    let pinged = send(
        &w,
        &w.alice,
        reply("yes", original["id"].as_str().unwrap(), true),
    )
    .await;
    let id = pinged["id"].as_str().unwrap();

    let edited = w
        .app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}/messages/{id}", w.channel),
            Some(&w.alice),
            Some(json!({ "content": "yes, at noon" })),
        ))
        .await
        .unwrap();
    assert!(edited.status().is_success());
    assert!(
        mentions_me(&w, &w.bob, id).await,
        "the edit dropped the reply ping"
    );
}
