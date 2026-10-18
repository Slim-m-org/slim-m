// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /channels/{channel_id}/threads`, the listing docs/IMPLIED-GAPS.md
//! named as missing entirely - before it, the only way to find a thread was
//! from the message it hangs off - plus the two things riding alongside it:
//! per-thread unread state (on the listing and on `Message.thread_unread_count`)
//! and the per-channel thread ceiling `openThread` now enforces.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{MAX_THREADS_PER_CHANNEL, NewMessage, OpenThreadError, Store};
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

/// Registers an account. The first call claims the deployment and seeds the
/// `general` channel these tests reuse; every later call joins as a plain
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

async fn list_threads(app: &Router, channel: &str, token: &str) -> axum::response::Response {
    app.clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel}/threads"),
            token,
            None,
        ))
        .await
        .unwrap()
}

/// The whole shape in one test: two threads, newest-activity-first order,
/// the parent's own snippet and author flattened onto the row, and a
/// zero-reply thread carrying a genuine `0` rather than being absent.
#[tokio::test]
async fn listing_returns_threads_newest_activity_first_with_the_parent_snippet() {
    let (store, _guard) = new_store("slimm-thread-listing-order").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent_a = send(&app, &messages, &admin, "first root message").await;
    let parent_a_id = parent_a["id"].as_str().unwrap().to_owned();
    let thread_a = open_thread(&app, &messages, &parent_a_id, &admin).await;
    let thread_a_id = thread_a["id"].as_str().unwrap().to_owned();

    let parent_b = send(&app, &messages, &admin, "second root message").await;
    let parent_b_id = parent_b["id"].as_str().unwrap().to_owned();
    let thread_b = open_thread(&app, &messages, &parent_b_id, &admin).await;
    let thread_b_id = thread_b["id"].as_str().unwrap().to_owned();

    // Past the millisecond activity is measured in, or the reply ties thread_b's opening.
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;

    // Reply into the *older* thread last, so activity order and open order disagree.
    send(
        &app,
        &format!("/channels/{thread_a_id}/messages"),
        &admin,
        "a reply",
    )
    .await;

    let listed = json_body(list_threads(&app, &channel, &admin).await).await;
    let rows = listed.as_array().unwrap();
    assert_eq!(rows.len(), 2);

    // thread_a was opened first but replied to last, so it must sort first.
    assert_eq!(rows[0]["id"], thread_a_id);
    assert_eq!(rows[0]["parent_message_id"], parent_a_id);
    assert_eq!(rows[0]["parent_content"], "first root message");
    assert_eq!(rows[0]["reply_count"], 1);
    assert!(rows[0]["last_reply_at"].is_i64());

    assert_eq!(rows[1]["id"], thread_b_id);
    assert_eq!(rows[1]["parent_content"], "second root message");
    assert_eq!(
        rows[1]["reply_count"], 0,
        "a thread with no replies is a genuine 0, not absent"
    );
    assert!(rows[1]["last_reply_at"].is_null());
}

/// One check, on the channel a listing is asked for - never a per-thread
/// filter, since every thread in one channel resolves to the same parent.
#[tokio::test]
async fn listing_threads_needs_view_channel_in_the_parent() {
    let (store, _guard) = new_store("slimm-thread-listing-permission").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let (bob_id, bob) = register(&store, "bob").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    open_thread(&app, &messages, &parent_id, &admin).await;

    // Before any overwrite, bob inherits view access and sees the thread.
    let before = list_threads(&app, &channel, &bob).await;
    assert_eq!(before.status(), StatusCode::OK);
    assert_eq!(
        json_body(before).await.as_array().unwrap().len(),
        1,
        "an ordinary member must see the channel's one thread"
    );

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

    let after = list_threads(&app, &channel, &bob).await;
    assert_eq!(
        after.status(),
        StatusCode::FORBIDDEN,
        "denying VIEW_CHANNEL in the parent must refuse the thread listing exactly like listMessages"
    );
}

/// The listing's own `unread_count`, and the identical field batch-loaded
/// onto the parent message (`Message.thread_unread_count`): both read the
/// same read-tracking every channel already has, and both answer 0 once the
/// viewer has actually read the thread.
#[tokio::test]
async fn unread_count_reflects_the_callers_own_read_state() {
    let (store, _guard) = new_store("slimm-thread-listing-unread").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let (_bob_id, bob) = register(&store, "bob").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    let thread = open_thread(&app, &messages, &parent_id, &admin).await;
    let thread_id = thread["id"].as_str().unwrap().to_owned();
    let thread_messages = format!("/channels/{thread_id}/messages");

    let reply = send(&app, &thread_messages, &admin, "one").await;
    send(&app, &thread_messages, &admin, "two").await;

    // Bob has never read the thread: two unread, both on the listing and on the parent message.
    let listed = json_body(list_threads(&app, &channel, &bob).await).await;
    assert_eq!(listed.as_array().unwrap()[0]["unread_count"], 2);

    let parent_row = json_body(
        app.clone()
            .oneshot(request("GET", &messages, &bob, None))
            .await
            .unwrap(),
    )
    .await;
    let parent_row = parent_row
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == parent_id)
        .unwrap();
    assert_eq!(parent_row["thread_unread_count"], 2);

    // Bob reads up to (and including) the first reply, so exactly one remains.
    let mark = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{thread_id}/read"),
            &bob,
            Some(json!({ "seq": reply["seq"] })),
        ))
        .await
        .unwrap();
    assert_eq!(mark.status(), StatusCode::OK);

    let listed_after = json_body(list_threads(&app, &channel, &bob).await).await;
    assert_eq!(listed_after.as_array().unwrap()[0]["unread_count"], 1);
}

/// A thread nobody has replied to yet still carries a genuine `0`, not
/// `null` - the same "opened but empty is real data" rule
/// `thread_reply_count` already follows for the reply count itself.
#[tokio::test]
async fn a_message_with_no_thread_carries_no_unread_field() {
    let (store, _guard) = new_store("slimm-thread-listing-no-thread").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    send(&app, &messages, &admin, "no thread here").await;

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", &messages, &admin, None))
            .await
            .unwrap(),
    )
    .await;
    assert!(listed.as_array().unwrap()[0]["thread_unread_count"].is_null());
}

/// The store-level ceiling `open_thread` enforces, driven directly rather
/// than through HTTP: the point is the ceiling, and 500 round trips would
/// only prove the same thing slower - the same call `read_bounds.rs` makes
/// for `MAX_PINS_PER_CHANNEL`.
#[tokio::test]
async fn a_channel_refuses_a_new_thread_past_its_ceiling() {
    let (store, _guard) = new_store("slimm-thread-listing-ceiling").await;
    let account = store
        .create_account("root", "root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let author: UserId = account.id;
    let channel: ChannelId = store.list_channels().await.unwrap()[0].id;

    let mut first_parent: Option<MessageId> = None;
    for index in 0..MAX_THREADS_PER_CHANNEL {
        let parent = store
            .send_message(NewMessage::plain(
                channel,
                author,
                MessageId::generate(),
                &format!("root {index}"),
            ))
            .await
            .unwrap()
            .message;
        store.open_thread(channel, parent.id).await.unwrap();
        if first_parent.is_none() {
            first_parent = Some(parent.id);
        }
    }

    let one_more = store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            "one too many",
        ))
        .await
        .unwrap()
        .message;
    assert!(
        matches!(
            store.open_thread(channel, one_more.id).await,
            Err(OpenThreadError::TooMany)
        ),
        "the ceiling must refuse, not silently accumulate"
    );

    // Idempotence must survive the ceiling: reopening an existing thread is free.
    store
        .open_thread(channel, first_parent.unwrap())
        .await
        .expect("reopening an already-open thread must not count against the ceiling");
}
