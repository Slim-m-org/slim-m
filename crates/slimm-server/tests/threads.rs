// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! HTTP and store integration tests for threads: a thread is a channel with
//! `parent_message_id` set (docs/decisions/0005-threads.md), so what needs
//! testing is exactly the seam the decision record named - permission
//! inheritance, the rail exclusion, and the last-channel guard - rather than
//! anything about sending or listing messages themselves, which a thread
//! gets for free by being an ordinary channel.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{json_body, request_authed as request};

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn app(store: Store) -> Router {
    let auth = Auth::new(2).expect("auth service");
    support::app::builder(store).auth(auth).router()
}

/// Registers an account and returns its id and access token. The first call
/// claims the deployment (`bootstrap_deployment`) and becomes its
/// administrator, seeding the `general` channel these tests reuse; every
/// later call finds the deployment already claimed and joins as a plain
/// `@everyone` member.
async fn register(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (account.id.to_string(), token)
}

async fn send(app: &Router, uri: &str, token: &str, content: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "POST",
                uri,
                token,
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await
}

async fn open_thread(app: &Router, messages: &str, message_id: &str, token: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("{messages}/{message_id}/thread"),
                token,
                None,
            ))
            .await
            .unwrap(),
    )
    .await
}

#[tokio::test]
async fn opening_a_thread_returns_a_channel_absent_from_list_channels() {
    let (store, _guard) = new_store("slimm-threads-list").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent = send(&app, &messages, &admin, "start a thread here").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();

    let thread = open_thread(&app, &messages, &parent_id, &admin).await;
    let thread_id = thread["id"].as_str().unwrap().to_owned();
    assert_eq!(thread["parent_message_id"], parent_id);
    assert_eq!(thread["kind"], "text");

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/channels", &admin, None))
            .await
            .unwrap(),
    )
    .await;
    let ids: Vec<String> = listed
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["id"].as_str().unwrap().to_owned())
        .collect();
    assert!(
        !ids.contains(&thread_id),
        "a thread must never appear in listChannels, got {ids:?}"
    );
}

#[tokio::test]
async fn opening_a_thread_twice_returns_the_same_channel() {
    let (store, _guard) = new_store("slimm-threads-idempotent").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();

    let first = open_thread(&app, &messages, &parent_id, &admin).await;
    let second = open_thread(&app, &messages, &parent_id, &admin).await;
    assert_eq!(first["id"], second["id"]);
}

/// Nesting is refused rather than built: `permission_channel` resolves one
/// hop, so a thread of a thread would evaluate against the inner thread's own
/// empty overwrite bucket instead of the real channel's, silently dropping
/// whatever deny the real channel had set.
#[tokio::test]
async fn opening_a_thread_on_a_message_inside_a_thread_is_refused() {
    let (store, _guard) = new_store("slimm-threads-no-nesting").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    let thread = open_thread(&app, &messages, &parent_id, &admin).await;
    let thread_id = thread["id"].as_str().unwrap().to_owned();
    let thread_messages = format!("/channels/{thread_id}/messages");

    let reply = send(&app, &thread_messages, &admin, "a reply inside the thread").await;
    let reply_id = reply["id"].as_str().unwrap().to_owned();

    let nested = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("{thread_messages}/{reply_id}/thread"),
            &admin,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(nested.status(), StatusCode::BAD_REQUEST);
}

/// The permission-inheritance seam the decision record's whole recommendation
/// rests on: a thread carries no `channel_overwrites` of its own, so denying
/// a specific member `VIEW_CHANNEL` in the parent - and nowhere else - must
/// reach into every thread opened on it too.
#[tokio::test]
async fn a_thread_inherits_the_parent_channels_view_permission() {
    let (store, _guard) = new_store("slimm-threads-inherit-view").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let (bob_id, bob) = register(&store, "bob").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    let thread = open_thread(&app, &messages, &parent_id, &admin).await;
    let thread_id = thread["id"].as_str().unwrap().to_owned();
    let thread_messages = format!("/channels/{thread_id}/messages");

    // Before any overwrite, bob inherits read access from the parent already.
    let before = app
        .clone()
        .oneshot(request("GET", &thread_messages, &bob, None))
        .await
        .unwrap();
    assert_eq!(before.status(), StatusCode::OK);

    let overwrite_uri = format!("/channels/{channel}/overwrites/member/{bob_id}");
    let set = app
        .clone()
        .oneshot(request(
            "PUT",
            &overwrite_uri,
            &admin,
            Some(json!({ "allow": 0, "deny": Permissions::VIEW_CHANNEL.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(set.status(), StatusCode::NO_CONTENT);

    let denied_parent = app
        .clone()
        .oneshot(request("GET", &messages, &bob, None))
        .await
        .unwrap();
    assert_eq!(denied_parent.status(), StatusCode::FORBIDDEN);

    let denied_thread = app
        .clone()
        .oneshot(request("GET", &thread_messages, &bob, None))
        .await
        .unwrap();
    assert_eq!(
        denied_thread.status(),
        StatusCode::FORBIDDEN,
        "a member overwrite on the parent must deny the thread too, with no overwrite of its own"
    );
}

/// Starting a thread is a way of sending, not a way of managing the channel:
/// it needs SEND_MESSAGES in the parent, the same bit a plain send needs
/// there, not merely VIEW_CHANNEL.
#[tokio::test]
async fn opening_a_thread_needs_send_permission_in_the_parent() {
    let (store, _guard) = new_store("slimm-threads-open-needs-send").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let (bob_id, bob) = register(&store, "bob").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();

    let overwrite_uri = format!("/channels/{channel}/overwrites/member/{bob_id}");
    app.clone()
        .oneshot(request(
            "PUT",
            &overwrite_uri,
            &admin,
            Some(json!({ "allow": 0, "deny": Permissions::SEND_MESSAGES.bits() })),
        ))
        .await
        .unwrap();

    let opened = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("{messages}/{parent_id}/thread"),
            &bob,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        opened.status(),
        StatusCode::FORBIDDEN,
        "bob can still view the channel, but denying send must refuse opening a thread in it"
    );
}

/// The bug the decision record named by name: a thread inflating the count
/// the last-channel guard reads would let the deployment's one real channel
/// be deleted while it still has nowhere for anyone to land.
#[tokio::test]
async fn a_thread_does_not_count_toward_the_last_channel_guard() {
    let (store, _guard) = new_store("slimm-threads-last-channel").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    open_thread(&app, &messages, &parent_id, &admin).await;

    let delete = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{channel}"),
            &admin,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        delete.status(),
        StatusCode::CONFLICT,
        "the deployment's one real channel must stay undeletable however many threads hang off it"
    );
}

/// The batch lookup `with_reactions` attaches to every message: a client that
/// was never online to see a thread opened still learns it exists on the
/// next fetch of the channel it hangs off.
#[tokio::test]
async fn a_message_carries_its_thread_channel_id_once_one_is_opened() {
    let (store, _guard) = new_store("slimm-threads-discovery").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    assert!(parent["thread_channel_id"].is_null());

    let thread = open_thread(&app, &messages, &parent_id, &admin).await;
    let thread_id = thread["id"].as_str().unwrap().to_owned();

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", &messages, &admin, None))
            .await
            .unwrap(),
    )
    .await;
    let row = listed
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == parent_id)
        .unwrap();
    assert_eq!(row["thread_channel_id"], thread_id);
}
