// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Closing a DM out of the sidebar: a per-viewer hide, never a delete. See
//! `dm_hides` (0057_dm_hides.sql) and `Store::hide_dm_conversation`.
//!
//! Covers the one behavior that makes this feel right rather than lossy: a
//! hidden DM comes back on its own once the other person writes again, and
//! also the moment the caller reopens (or re-messages) the same person - plus
//! that it never touches messages, mute, blocking, or the other side's own
//! list, and that it leaves with the caller's own account.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::notifications::NotificationPreference;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, register_token_id as register, request};

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

async fn list_dm_channel_ids(app: &Router, token: &str) -> Vec<String> {
    let response = app
        .clone()
        .oneshot(request("GET", "/dms", Some(token), None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response)
        .await
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["channel_id"].as_str().unwrap().to_owned())
        .collect()
}

async fn hide(app: &Router, token: &str, target_id: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "DELETE",
            &format!("/dms/{target_id}"),
            Some(token),
            None,
        ))
        .await
        .unwrap()
        .status()
}

async fn open(app: &Router, token: &str, target_id: &str) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/dms/{target_id}"),
            Some(token),
            None,
        ))
        .await
        .unwrap();
    let status = response.status();
    (status, json_body(response).await)
}

async fn send(app: &Router, channel_id: &str, token: &str, content: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": content })),
        ))
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn hiding_removes_it_from_the_caller_own_list_only() {
    let (store, _guard) = new_store("slimm-dm-hides-basic").await;
    let app = app(store.clone());
    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;
    let (_status, alice_dm) = open(&app, &alice_token, &bob_id).await;
    let channel_id = alice_dm["channel_id"].as_str().unwrap().to_owned();

    assert_eq!(
        hide(&app, &alice_token, &bob_id).await,
        StatusCode::NO_CONTENT
    );

    assert!(
        !list_dm_channel_ids(&app, &alice_token)
            .await
            .contains(&channel_id),
        "alice hid it, so it must not be in her own list"
    );
    assert!(
        list_dm_channel_ids(&app, &bob_token)
            .await
            .contains(&channel_id),
        "bob never hid anything; his own list is unaffected by alice's action"
    );
}

/// The behavior most likely to be got wrong: a hidden DM must come back on
/// its own once the other person writes again, or the hide silently drops
/// future conversation.
#[tokio::test]
async fn a_hidden_dm_reappears_once_the_other_person_sends_something_new() {
    let (store, _guard) = new_store("slimm-dm-hides-reappear-message").await;
    let app = app(store.clone());
    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;
    let (_status, opened) = open(&app, &alice_token, &bob_id).await;
    let channel_id = opened["channel_id"].as_str().unwrap().to_owned();

    hide(&app, &alice_token, &bob_id).await;
    assert!(
        !list_dm_channel_ids(&app, &alice_token)
            .await
            .contains(&channel_id)
    );

    assert_eq!(
        send(&app, &channel_id, &bob_token, "hey, you there?").await,
        StatusCode::OK
    );

    assert!(
        list_dm_channel_ids(&app, &alice_token)
            .await
            .contains(&channel_id),
        "new activity from the other side must bring a hidden DM back"
    );
}

/// The other way back: the caller reopening (or re-messaging through the
/// open route) the same person un-hides it immediately, with no new message
/// required from either side.
#[tokio::test]
async fn a_hidden_dm_reappears_when_the_caller_reopens_it() {
    let (store, _guard) = new_store("slimm-dm-hides-reappear-open").await;
    let app = app(store.clone());
    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;
    let (_status, opened) = open(&app, &alice_token, &bob_id).await;
    let channel_id = opened["channel_id"].as_str().unwrap().to_owned();

    hide(&app, &alice_token, &bob_id).await;
    assert!(
        !list_dm_channel_ids(&app, &alice_token)
            .await
            .contains(&channel_id)
    );

    let (status, _) = open(&app, &alice_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);

    assert!(
        list_dm_channel_ids(&app, &alice_token)
            .await
            .contains(&channel_id),
        "the caller opening the same pair again must bring it back on its own"
    );
}

/// Hiding a pair with no channel yet is a no-op, not a 404: "not in my list"
/// is already true.
#[tokio::test]
async fn hiding_a_dm_that_was_never_opened_is_a_silent_no_op() {
    let (store, _guard) = new_store("slimm-dm-hides-noop").await;
    let app = app(store.clone());
    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;

    assert_eq!(
        hide(&app, &alice_token, &bob_id).await,
        StatusCode::NO_CONTENT
    );
}

/// Hiding is one preference among several a caller can hold about the same
/// DM, and it must not read or write either of the other two: muting the
/// channel is untouched by hiding it, and blocking someone does not itself
/// hide (or unhide) a conversation with them.
#[tokio::test]
async fn hiding_is_independent_of_mute_and_block() {
    let (store, _guard) = new_store("slimm-dm-hides-independent").await;
    let alice = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let bob = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();
    let channel = store.open_dm(alice.id, bob.id).await.unwrap();

    store
        .set_channel_notification_preference(alice.id, channel.id, NotificationPreference::Nothing)
        .await
        .unwrap();
    store.hide_dm_conversation(alice.id, bob.id).await.unwrap();

    // Hiding did not touch the mute override.
    assert_eq!(
        store
            .channel_notification_preference(alice.id, channel.id)
            .await
            .unwrap(),
        Some(NotificationPreference::Nothing)
    );
    // And it is genuinely hidden regardless of the mute.
    assert!(
        !store
            .list_dm_conversations(alice.id)
            .await
            .unwrap()
            .iter()
            .any(|c| c.channel_id == channel.id)
    );

    // Blocking bob neither hides nor unhides anything by itself.
    store.block_user(alice.id, bob.id).await.unwrap();
    assert!(
        !store
            .list_dm_conversations(alice.id)
            .await
            .unwrap()
            .iter()
            .any(|c| c.channel_id == channel.id),
        "still hidden - blocking must not have unhidden it"
    );
}

/// Hidden state is the caller's own preference, purged with their account the
/// same way `user_notes` is - `tests/user_notes.rs`'s own purge test is the
/// template this follows, including keeping a separate administrator around
/// so deleting alice never strands the deployment.
#[tokio::test]
async fn hidden_state_is_purged_with_the_hider_own_account() {
    let (store, pool, _guard) = {
        let (path, guard) = support::TestDbGuard::new("slimm-dm-hides-purge");
        let config = Config {
            port: 0,
            database_path: path,
            hash_concurrency: 2,
            ..Config::default()
        };
        let pool = db::connect(&config).await.expect("connect + migrate");
        (Store::new(pool.clone()), pool, guard)
    };

    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let alice = store
        .create_account("alice", "Alice", "not-a-real-hash")
        .await
        .unwrap();
    let bob = store
        .create_account("bob", "Bob", "not-a-real-hash")
        .await
        .unwrap();
    store.open_dm(alice.id, bob.id).await.unwrap();
    store.hide_dm_conversation(alice.id, bob.id).await.unwrap();

    store.delete_account(alice.id).await.unwrap();

    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM dm_hides WHERE user_id = ?")
        .bind(alice.id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(
        count, 0,
        "a leftover hide row keyed to a deleted account is a privacy bug"
    );
}
