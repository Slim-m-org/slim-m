// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A reply can ping the author it replies to, Discord style (backlog #249):
//! with mention_reply the author sees mentions_me, without it the reply stays
//! quiet, a reply to yourself never pings, and an edit keeps the ping - but
//! only one the send stored, and only while the author can still see it.

use axum::Router;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;
use support::overwrite_harness::{app, json_body, new_store, register, request};

struct World {
    app: Router,
    store: Store,
    channel: String,
    alice: String,
    bob: String,
    bob_id: String,
    _guard: support::TestDbGuard,
}

async fn world(name: &str) -> World {
    let (store, guard) = new_store(name).await;
    let (alice, _) = register(&store, "alice").await;
    let (bob, bob_id) = register(&store, "bob").await;
    let channel = support::overwrite_harness::general_channel_id(&store).await;
    World {
        app: app(store.clone()),
        store,
        channel,
        alice,
        bob,
        bob_id,
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

    edit(&w, &w.alice, id, "yes, at noon").await;
    assert!(
        mentions_me(&w, &w.bob, id).await,
        "the edit dropped the reply ping"
    );
}

async fn edit(w: &World, token: &str, id: &str, content: &str) {
    let edited = w
        .app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}/messages/{id}", w.channel),
            Some(token),
            Some(json!({ "content": content })),
        ))
        .await
        .unwrap();
    assert!(edited.status().is_success());
}

async fn stored_mention(w: &World, id: &str, user: &str) -> bool {
    w.store
        .is_mentioned(
            MessageId(id.parse().unwrap()),
            UserId(user.parse().unwrap()),
        )
        .await
        .unwrap()
}

#[tokio::test]
async fn an_edit_drops_a_text_mention_of_the_author_that_was_not_a_reply_ping() {
    let w = world("slimm-reply-mention-text").await;
    let original = send(
        &w,
        &w.bob,
        json!({ "id": Uuid::now_v7().to_string(), "content": "lunch?" }),
    )
    .await;
    let quiet = send(
        &w,
        &w.alice,
        reply("@bob yes", original["id"].as_str().unwrap(), false),
    )
    .await;
    let id = quiet["id"].as_str().unwrap();
    assert!(mentions_me(&w, &w.bob, id).await, "the @bob in the text");

    edit(&w, &w.alice, id, "yes").await;
    assert!(
        !mentions_me(&w, &w.bob, id).await,
        "an edit that removed @bob kept the mention"
    );
}

#[tokio::test]
async fn an_edit_drops_the_ping_once_the_author_cannot_see_the_channel() {
    let w = world("slimm-reply-mention-hidden").await;
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
    assert!(stored_mention(&w, id, &w.bob_id).await);

    w.store
        .set_member_overwrite(
            ChannelId(w.channel.parse().unwrap()),
            UserId(w.bob_id.parse().unwrap()),
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    edit(&w, &w.alice, id, "yes, at noon").await;
    assert!(
        !stored_mention(&w, id, &w.bob_id).await,
        "an edit re-stored a ping for someone who can no longer see it"
    );
}

#[tokio::test]
async fn a_reply_to_someone_who_cannot_see_the_channel_does_not_ping_them() {
    let w = world("slimm-reply-mention-viewer").await;
    let original = send(
        &w,
        &w.bob,
        json!({ "id": Uuid::now_v7().to_string(), "content": "lunch?" }),
    )
    .await;
    w.store
        .set_member_overwrite(
            ChannelId(w.channel.parse().unwrap()),
            UserId(w.bob_id.parse().unwrap()),
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let pinged = send(
        &w,
        &w.alice,
        reply("yes", original["id"].as_str().unwrap(), true),
    )
    .await;
    assert!(!stored_mention(&w, pinged["id"].as_str().unwrap(), &w.bob_id).await);
}
