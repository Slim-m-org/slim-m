// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A reply in a thread you started or replied in counts as a mention for you (docs/decisions/0005-threads.md),
//! so `mentions_me`, and with it the unread mention badge, agree with the alert.

use axum::Router;
use serde_json::{Value, json};
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
    thread: String,
    alice: String,
    bob: String,
    carol: String,
    _guard: support::TestDbGuard,
}

async fn post(app: &Router, uri: &str, token: &str, body: Option<Value>) -> Value {
    json_body(
        app.clone()
            .oneshot(request("POST", uri, Some(token), body))
            .await
            .unwrap(),
    )
    .await
}

fn message(text: &str) -> Option<Value> {
    Some(json!({ "id": Uuid::now_v7().to_string(), "content": text }))
}

/// Alice's root message has a thread; bob and carol can both see it.
async fn world(name: &str) -> World {
    let (store, guard) = new_store(name).await;
    let (alice, _) = register(&store, "alice").await;
    let (bob, _) = register(&store, "bob").await;
    let (carol, _) = register(&store, "carol").await;
    let app = app(store.clone());
    let channel = general_channel_id(&store).await;
    let root = post(
        &app,
        &format!("/channels/{channel}/messages"),
        &alice,
        message("root"),
    )
    .await;
    let root_id = root["id"].as_str().unwrap();
    let thread = post(
        &app,
        &format!("/channels/{channel}/messages/{root_id}/thread"),
        &alice,
        None,
    )
    .await;
    World {
        app,
        store,
        thread: thread["id"].as_str().unwrap().to_owned(),
        alice,
        bob,
        carol,
        _guard: guard,
    }
}

async fn reply(w: &World, token: &str, text: &str) -> String {
    let sent = post(
        &w.app,
        &format!("/channels/{}/messages", w.thread),
        token,
        message(text),
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
                &format!("/channels/{}/messages", w.thread),
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

#[tokio::test]
async fn a_reply_mentions_whoever_started_or_replied_in_the_thread_but_not_a_bystander() {
    let w = world("slimm-thread-reply-mention").await;
    let bobs = reply(&w, &w.bob.clone(), "first reply").await;
    assert!(
        mentions_me(&w, &w.alice, &bobs).await,
        "the thread's starter"
    );
    assert!(
        !mentions_me(&w, &w.carol, &bobs).await,
        "a bystander who never joined"
    );
    assert!(
        !mentions_me(&w, &w.bob, &bobs).await,
        "the author is never alerted by their own reply"
    );

    let alices = reply(&w, &w.alice.clone(), "second reply").await;
    assert!(
        mentions_me(&w, &w.bob, &alices).await,
        "someone who replied earlier"
    );
    assert!(
        !mentions_me(&w, &w.alice, &alices).await,
        "the author again"
    );
    assert!(!mentions_me(&w, &w.carol, &alices).await);
}

#[tokio::test]
async fn a_reply_in_an_ordinary_channel_mentions_nobody() {
    let w = world("slimm-thread-reply-mention-plain").await;
    let channel = general_channel_id(&w.store).await;
    let uri = format!("/channels/{channel}/messages");
    let sent = post(&w.app, &uri, &w.bob, message("not in a thread")).await;
    let listed = json_body(
        w.app
            .clone()
            .oneshot(request("GET", &uri, Some(&w.alice), None))
            .await
            .unwrap(),
    )
    .await;
    let found = listed
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == sent["id"])
        .unwrap();
    assert_eq!(found["mentions_me"], false);
}
