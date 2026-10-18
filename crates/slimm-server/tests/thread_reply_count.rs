// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The "N replies" affordance `docs/decisions/0005-threads.md` named as not
//! built: `Store::thread_summaries_for_messages` batch-loads a reply count
//! and a last-reply timestamp onto whichever message opened a thread, the
//! same shape `threads.rs`'s own `thread_channel_id` discovery test already
//! covers. What is specific to this file: the count is right, a deleted
//! reply is excluded from both the count and the timestamp, a message with
//! no thread carries none of these fields, and the lookup is one query for
//! the whole page rather than one per message.

use std::fs;
use std::path::Path;

use axum::Router;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::MessageId;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{json_body, register_id_token as register, request_authed as request};

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

fn parse_message_id(value: &Value) -> MessageId {
    MessageId(Uuid::parse_str(value["id"].as_str().unwrap()).unwrap())
}

async fn list(app: &Router, messages: &str, token: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request("GET", messages, token, None))
            .await
            .unwrap(),
    )
    .await
}

fn find<'a>(listed: &'a Value, id: &str) -> &'a Value {
    listed
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == id)
        .unwrap()
}

/// A short gap so two replies sent back to back never land on the same
/// millisecond, which the deleted-reply test below depends on to tell one
/// reply's `created_at` from another's.
async fn settle() {
    tokio::time::sleep(std::time::Duration::from_millis(2)).await;
}

/// Core correctness: the count is exactly the live replies, and a deleted
/// one drops out of both the count and `thread_last_reply_at`, never leaving
/// the newest *ever sent* reply's timestamp behind once that reply is gone.
#[tokio::test]
async fn reply_count_and_last_reply_at_exclude_deleted_replies() {
    let (store, _guard) = new_store("slimm-thread-reply-count-deleted").await;
    let (admin_id, admin) = register(&store, "admin").await;
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");
    let app = app(store.clone());

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    let thread = open_thread(&app, &messages, &parent_id, &admin).await;
    let thread_id = thread["id"].as_str().unwrap().to_owned();
    let thread_messages = format!("/channels/{thread_id}/messages");

    send(&app, &thread_messages, &admin, "one").await;
    settle().await;
    let reply2 = send(&app, &thread_messages, &admin, "two").await;
    settle().await;
    let reply3 = send(&app, &thread_messages, &admin, "three").await;
    let reply2_created_at = reply2["created_at"].as_i64().unwrap();
    let reply3_id = parse_message_id(&reply3);

    let before = find(&list(&app, &messages, &admin).await, &parent_id).clone();
    assert_eq!(before["thread_reply_count"], 3);
    assert_eq!(
        before["thread_last_reply_at"].as_i64().unwrap(),
        reply3["created_at"].as_i64().unwrap()
    );

    // The count must fall to 2 and the timestamp back to reply2's, not reply3's.
    store.delete_message(reply3_id, admin_id).await.unwrap();

    let after = find(&list(&app, &messages, &admin).await, &parent_id).clone();
    assert_eq!(
        after["thread_reply_count"], 2,
        "a deleted reply must not count"
    );
    assert_eq!(
        after["thread_last_reply_at"].as_i64().unwrap(),
        reply2_created_at,
        "the deleted reply's timestamp must not survive as the last-reply marker"
    );
}

/// A message that never had a thread opened on it carries none of the three
/// fields - not `thread_channel_id`, and not an empty-looking `0` for the
/// count either, which would read as a thread that exists and has no
/// replies rather than as no thread at all.
#[tokio::test]
async fn a_message_with_no_thread_carries_no_reply_fields() {
    let (store, _guard) = new_store("slimm-thread-reply-count-none").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");
    let app = app(store.clone());

    send(&app, &messages, &admin, "no thread here").await;

    let listed = list(&app, &messages, &admin).await;
    let row = &listed.as_array().unwrap()[0];
    assert!(row["thread_channel_id"].is_null());
    assert!(
        row["thread_reply_count"].is_null(),
        "no thread must never read as a zero-reply thread"
    );
    assert!(row["thread_last_reply_at"].is_null());
}

/// Opening a thread creates its channel before anything is sent into it, so
/// the summary must exist (the thread is real) with a genuine `0`, not be
/// absent the way a message with no thread at all is. Client-side this is
/// the same "no affordance" outcome as no thread, but the wire data itself
/// has to tell the two situations apart or a client could never render "a
/// thread was started" once the first reply lands.
#[tokio::test]
async fn an_opened_thread_with_no_replies_reports_zero_and_no_timestamp() {
    let (store, _guard) = new_store("slimm-thread-reply-count-zero").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");
    let app = app(store.clone());

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    open_thread(&app, &messages, &parent_id, &admin).await;

    let listed = list(&app, &messages, &admin).await;
    let row = find(&listed, &parent_id);
    assert!(!row["thread_channel_id"].is_null());
    assert_eq!(row["thread_reply_count"], 0);
    assert!(row["thread_last_reply_at"].is_null());
}

/// A page of many messages with threads is resolved through the batch
/// lookup correctly for every one of them, proving the single call this
/// test makes covers the whole set rather than needing one call per id.
#[tokio::test]
async fn thread_summaries_resolve_a_whole_page_of_messages_in_one_call() {
    let (store, _guard) = new_store("slimm-thread-reply-count-batch").await;
    let (author, _token) = register(&store, "admin").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    let mut parents = Vec::new();
    for i in 0..12 {
        let parent = store
            .send_message(NewMessage::plain(
                channel,
                author,
                MessageId::generate(),
                &format!("m{i}"),
            ))
            .await
            .unwrap()
            .message;
        // Only even-indexed messages get a thread, so the batch answer must report both.
        if i % 2 == 0 {
            let thread = store.open_thread(channel, parent.id).await.unwrap().channel;
            for r in 0..(i / 2) {
                store
                    .send_message(NewMessage::plain(
                        thread.id,
                        author,
                        MessageId::generate(),
                        &format!("reply {r}"),
                    ))
                    .await
                    .unwrap();
            }
        }
        parents.push(parent.id);
    }

    let summaries = store.thread_summaries_for_messages(&parents).await.unwrap();
    for (i, parent_id) in parents.iter().enumerate() {
        let found = summaries.iter().find(|(id, _)| id == parent_id);
        if i % 2 == 0 {
            let (_, summary) = found.unwrap_or_else(|| panic!("message {i} should have a thread"));
            assert_eq!(
                summary.reply_count,
                (i / 2) as i64,
                "message {i}'s reply count"
            );
        } else {
            assert!(found.is_none(), "message {i} was never given a thread");
        }
    }
}

/// Uses `support::function_body`, the same shared helper `canvas_index.rs`
/// reads a function's body out of its real source with rather than a copy:
/// proves the batch lookup issues exactly one `fetch_all` (a single round
/// trip covering every id bound into its `IN (...)` list) and never a
/// `fetch_one`/`fetch_optional`, which is what a per-message query would
/// look like. This is the structural half of "one query for the page,
/// never one per message"; the behavioural half is
/// `thread_summaries_resolve_a_whole_page_of_messages_in_one_call` above,
/// which drives a page of a dozen messages through the one call this test
/// proves is the only one the function makes.
#[test]
fn thread_summaries_for_messages_is_exactly_one_query() {
    let source =
        fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("src/store/threads.rs"))
            .expect("read the threads store module");
    let body = support::function_body(&source, "pub async fn thread_summaries_for_messages(");
    assert_eq!(
        body.matches(".fetch_all(").count(),
        1,
        "the batch lookup must resolve the whole page in one round trip: {body}"
    );
    assert_eq!(
        body.matches(".fetch_one(").count() + body.matches(".fetch_optional(").count(),
        0,
        "a fetch inside this function would mean a query per message rather than per page: {body}"
    );
}
