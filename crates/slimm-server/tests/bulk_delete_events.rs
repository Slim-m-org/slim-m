// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `Event::MessageUnpinned` and `Event::ThreadUpdated` on the bulk-delete
//! path (MOD12).
//!
//! Split out of `message_bulk_delete.rs` to stay under the file budget: that
//! file already proves every other side effect the single delete has - see
//! its own doc comment - and this is the same coverage for the two live
//! signals `pin_delete_events.rs` and `message_delete.rs` add to the single
//! path. The batch-specific risk is one `ThreadUpdated` per request rather
//! than one per deleted reply, the same op-density reasoning
//! `message_bulk_delete.rs`'s own tests apply to `message_ops`.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::{MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{json_body_or_null as json_body, request};

async fn harness() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-bulk-delete-events");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

/// Keeps a handle to the hub so a test can subscribe and inspect what the
/// route actually published, the same shape `dm_open_publishes_no_event.rs`
/// uses.
fn app_with_hub(store: Store, hub: Hub) -> Router {
    support::app::builder(store).hub(hub).router()
}

async fn account(store: &Store, username: &str) -> (String, UserId) {
    let user = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    let tokens = store.open_session(user.id, "cli").await.unwrap();
    (tokens.access_token, user.id)
}

/// An administrator who owns the deployment, a moderator holding only
/// MANAGE_MESSAGES, and an ordinary member to be moderated; see
/// `message_bulk_delete.rs`'s own `people` for the same shape.
async fn people(store: &Store) -> ((String, UserId), (String, UserId), (String, UserId)) {
    let admin = account(store, "root").await;
    store.bootstrap_deployment(admin.1).await.unwrap();
    let moderator = account(store, "mod").await;
    let member = account(store, "nia").await;
    let role = store
        .create_role("mods", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    store.assign_role(moderator.1, role).await.unwrap();
    (admin, moderator, member)
}

async fn channel_id(store: &Store) -> String {
    store.list_channels().await.unwrap()[0].id.0.to_string()
}

async fn send(app: &Router, channel: &str, token: &str, content: &str) -> String {
    let body = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel}/messages"),
                Some(token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await;
    body["id"].as_str().unwrap().to_owned()
}

async fn bulk_delete(app: &Router, channel: &str, token: &str, ids: &[String]) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages/bulk-delete"),
            Some(token),
            Some(json!({ "message_ids": ids })),
        ))
        .await
        .unwrap()
        .status()
}

/// The single delete's own `MessageUnpinned`/`ThreadUpdated` coverage
/// (`pin_delete_events.rs`, `message_delete.rs`) has to hold for the bulk
/// path too, and a batch has its own way to get this wrong: one
/// `ThreadUpdated` per request rather than one per deleted reply.
#[tokio::test]
async fn bulk_delete_fires_message_unpinned_and_one_thread_updated() {
    let (store, _guard) = harness().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());

    let parent_id = send(&app, &channel, &member.0, "root").await;

    let opened = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages/{parent_id}/thread"),
            Some(&member.0),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(opened.status(), StatusCode::OK);
    let thread_id = json_body(opened).await["id"].as_str().unwrap().to_owned();

    let reply_a = send(&app, &thread_id, &member.0, "reply a").await;
    let reply_b = send(&app, &thread_id, &member.0, "reply b").await;

    let pin_status = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{thread_id}/messages/{reply_a}/pin"),
            Some(&moderator.0),
            None,
        ))
        .await
        .unwrap()
        .status();
    assert_eq!(pin_status, StatusCode::NO_CONTENT);

    let mut rx = hub.subscribe();
    let status = bulk_delete(
        &app,
        &thread_id,
        &moderator.0,
        &[reply_a.clone(), reply_b.clone()],
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let pinned_reply = MessageId(Uuid::parse_str(&reply_a).unwrap());
    let mut unpinned = false;
    let mut thread_updates = 0;
    let mut last_reply_count = None;
    while let Ok(event) = rx.try_recv() {
        match event {
            Event::MessageUnpinned { message_id, .. } if message_id == pinned_reply => {
                unpinned = true;
            }
            Event::ThreadUpdated { reply_count, .. } => {
                thread_updates += 1;
                last_reply_count = Some(reply_count);
            }
            _ => {}
        }
    }
    assert!(
        unpinned,
        "the pinned reply's bulk delete must publish MessageUnpinned"
    );
    assert_eq!(
        thread_updates, 1,
        "one ThreadUpdated for the whole batch, not one per deleted reply"
    );
    assert_eq!(
        last_reply_count,
        Some(0),
        "the count must reflect both replies gone, not just the last op"
    );
}

/// A batch that names only an already-deleted id claims nothing this call,
/// so it must publish neither signal - the bulk path's own idempotence,
/// mirrored from `message_bulk_delete.rs`'s
/// `an_already_deleted_id_is_skipped_rather_than_re_deleted`.
#[tokio::test]
async fn a_retry_batch_publishes_neither_signal() {
    let (store, _guard) = harness().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());

    let id = send(&app, &channel, &member.0, "spam").await;
    let ids = vec![id];
    assert_eq!(
        bulk_delete(&app, &channel, &moderator.0, &ids).await,
        StatusCode::NO_CONTENT
    );

    let mut rx = hub.subscribe();
    assert_eq!(
        bulk_delete(&app, &channel, &moderator.0, &ids).await,
        StatusCode::NO_CONTENT
    );
    assert!(
        rx.try_recv().is_err(),
        "a batch that deletes nothing must publish nothing"
    );
}
