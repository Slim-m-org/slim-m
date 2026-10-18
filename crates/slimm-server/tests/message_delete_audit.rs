// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The single-message delete path (`DELETE
//! /channels/{channelId}/messages/{messageId}`) never wrote to
//! `moderation_audit_log`, unlike its bulk sibling
//! (`message_bulk_delete.rs`'s `the_act_is_recorded_against_each_author`).
//! Decision 0016 rests on the audit log making every reach into someone
//! else's messages visible; a path that skips it is the compensating control
//! missing for exactly the reach the decision accepts.
//!
//! A self-delete stays unaudited: it needs no `MANAGE_MESSAGES` at all, so it
//! is not the moderation act the log exists to record.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use sqlx::SqlitePool;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body_or_null as json_body, request_authed as request};

async fn harness() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-message-delete-audit");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
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
/// MANAGE_MESSAGES, and an ordinary member to be moderated - the same shape
/// `message_bulk_delete.rs`'s own `people` uses.
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
                token,
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await;
    body["id"].as_str().unwrap().to_owned()
}

async fn delete(app: &Router, channel: &str, message_id: &str, token: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{channel}/messages/{message_id}"),
            token,
            None,
        ))
        .await
        .unwrap()
        .status()
}

async fn audit(pool: &SqlitePool) -> Vec<(String, Option<Vec<u8>>, Option<Vec<u8>>)> {
    sqlx::query_as("SELECT action, actor_id, subject_id FROM moderation_audit_log ORDER BY id")
        .fetch_all(pool)
        .await
        .expect("read the audit log")
}

/// The load-bearing case: a moderator reaching for another member's message
/// through the single-delete route leaves the same trail the bulk route
/// already does.
#[tokio::test]
async fn a_moderators_single_delete_of_anothers_message_is_recorded() {
    let (store, pool, _guard) = harness().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let message_id = send(&app, &channel, &member.0, "spam").await;

    assert_eq!(
        delete(&app, &channel, &message_id, &moderator.0).await,
        StatusCode::NO_CONTENT
    );

    assert_eq!(
        audit(&pool).await,
        vec![(
            "messages_deleted".to_owned(),
            Some(moderator.1.0.as_bytes().to_vec()),
            Some(member.1.0.as_bytes().to_vec()),
        )],
        "one row, naming the moderator as actor and the author as subject"
    );
}

/// Deleting your own message needs no `MANAGE_MESSAGES` at all, so it is not
/// the reach decision 0016 requires visibility for.
#[tokio::test]
async fn a_self_delete_writes_no_audit_row() {
    let (store, pool, _guard) = harness().await;
    let (_admin, _moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let message_id = send(&app, &channel, &member.0, "my own message").await;

    assert_eq!(
        delete(&app, &channel, &message_id, &member.0).await,
        StatusCode::NO_CONTENT
    );

    assert!(
        audit(&pool).await.is_empty(),
        "deleting your own message is not a moderation act"
    );
}

/// A retry of an already-deleted message is idempotent and must not write a
/// second row for the same act.
#[tokio::test]
async fn a_repeated_delete_writes_no_second_audit_row() {
    let (store, pool, _guard) = harness().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let message_id = send(&app, &channel, &member.0, "spam").await;
    assert_eq!(
        delete(&app, &channel, &message_id, &moderator.0).await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        delete(&app, &channel, &message_id, &moderator.0).await,
        StatusCode::NO_CONTENT,
        "a repeat is a success, not a 404"
    );

    assert_eq!(
        audit(&pool).await.len(),
        1,
        "the retry must not write a second act that never happened"
    );
}

/// The whole point: the row this path now writes is not stranded in a table
/// nothing reads. `/reports/history` (MOD4) already merges
/// `moderation_audit_log` with resolved reports, and a single-message delete's
/// row shows up there exactly like a bulk delete's does.
#[tokio::test]
async fn the_recorded_act_appears_in_reports_history() {
    let (store, _pool, _guard) = harness().await;
    let (admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());

    let message_id = send(&app, &channel, &member.0, "spam").await;
    assert_eq!(
        delete(&app, &channel, &message_id, &moderator.0).await,
        StatusCode::NO_CONTENT
    );

    let history = json_body(
        app.clone()
            .oneshot(request("GET", "/reports/history", &admin.0, None))
            .await
            .unwrap(),
    )
    .await;
    let items = history.as_array().unwrap();

    assert_eq!(
        items.len(),
        1,
        "expected exactly the one audit entry: {items:?}"
    );
    assert_eq!(items[0]["kind"], "audit_log");
    assert_eq!(items[0]["action"], "messages_deleted");
    assert_eq!(items[0]["actor_id"], moderator.1.to_string());
    assert_eq!(items[0]["subject_id"], member.1.to_string());
}
