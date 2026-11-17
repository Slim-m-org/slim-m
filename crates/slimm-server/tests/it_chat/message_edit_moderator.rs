// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A moderator rewriting someone else's message is audited as
//! `message_edited`, and the message says its text is a moderator's on the
//! edit response, history and the sync op stream, until the author edits it
//! again. Removing link previews (also an `edit` op) never counts.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use sqlx::SqlitePool;
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use support::app::{app, json_body, request};

async fn account(store: &Store, username: &str) -> (String, UserId) {
    let user = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    (
        store
            .open_session(user.id, "cli")
            .await
            .unwrap()
            .access_token,
        user.id,
    )
}

struct World {
    store: Store,
    pool: SqlitePool,
    app: Router,
    moderator: (String, UserId),
    member: (String, UserId),
    channel: ChannelId,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, pool, guard) = support::new_store_with_pool("slimm-moderator-edit").await;
    let admin = account(&store, "root").await;
    store.bootstrap_deployment(admin.1).await.unwrap();
    let moderator = account(&store, "mod").await;
    let member = account(&store, "nia").await;
    let role = store
        .create_role("mods", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    store.assign_role(moderator.1, role).await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap().id;
    World {
        app: app(store.clone()),
        store,
        pool,
        moderator,
        member,
        channel,
        _guard: guard,
    }
}

async fn call(w: &World, token: &str, method: &str, uri: &str, body: Option<Value>) -> Value {
    let response = w
        .app
        .clone()
        .oneshot(request(method, uri, Some(token), body))
        .await
        .unwrap();
    assert!(
        response.status().is_success(),
        "{method} {uri}: {}",
        response.status()
    );
    if response.status() == StatusCode::NO_CONTENT {
        return Value::Null;
    }
    json_body(response).await
}

async fn edit(w: &World, token: &str, message: &str, content: &str) -> Value {
    let uri = format!("/channels/{}/messages/{message}", w.channel);
    call(w, token, "PATCH", &uri, Some(json!({ "content": content }))).await
}

async fn listed_flag(w: &World) -> Value {
    let uri = format!("/channels/{}/messages", w.channel);
    call(w, &w.member.0, "GET", &uri, None).await[0]["edited_by_moderator"].clone()
}

async fn op_flag(w: &World) -> bool {
    let page = w.store.message_ops_since(w.channel, 0, 100).await.unwrap();
    page.ops.last().unwrap().edited_by_moderator
}

async fn audit(pool: &SqlitePool) -> Vec<String> {
    sqlx::query_scalar("SELECT action FROM moderation_audit_log ORDER BY id")
        .fetch_all(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn a_moderators_edit_is_audited_and_shown_until_the_author_edits_again() {
    let w = world().await;
    let sent = call(
        &w,
        &w.member.0,
        "POST",
        &format!("/channels/{}/messages", w.channel),
        Some(json!({ "id": Uuid::now_v7().to_string(), "content": "rude words" })),
    )
    .await;
    let id = sent["id"].as_str().unwrap().to_owned();

    let edited = edit(&w, &w.moderator.0, &id, "kind words").await;
    assert_eq!(edited["edited_by_moderator"], true);
    assert_eq!(listed_flag(&w).await, true);
    assert!(op_flag(&w).await);
    assert_eq!(audit(&w.pool).await, ["message_edited"]);
    let (actor, subject): (Vec<u8>, Vec<u8>) =
        sqlx::query_as("SELECT actor_id, subject_id FROM moderation_audit_log")
            .fetch_one(&w.pool)
            .await
            .unwrap();
    assert_eq!(actor, w.moderator.1.0.as_bytes().to_vec());
    assert_eq!(subject, w.member.1.0.as_bytes().to_vec());

    let edited = edit(&w, &w.member.0, &id, "my words again").await;
    assert!(edited.get("edited_by_moderator").is_none(), "{edited}");
    assert!(listed_flag(&w).await.is_null());
    assert!(!op_flag(&w).await);
    assert_eq!(
        audit(&w.pool).await,
        ["message_edited"],
        "a self-edit is not audited"
    );
}

#[tokio::test]
async fn a_moderator_removing_previews_is_not_an_edit_of_the_text() {
    let w = world().await;
    let sent = call(
        &w,
        &w.member.0,
        "POST",
        &format!("/channels/{}/messages", w.channel),
        Some(json!({ "id": Uuid::now_v7().to_string(), "content": "see https://example.com" })),
    )
    .await;
    let id = MessageId(sent["id"].as_str().unwrap().parse().unwrap());
    edit(
        &w,
        &w.member.0,
        &id.to_string(),
        "see https://example.com now",
    )
    .await;
    // The removal must land in a later millisecond than the edit, as it does for a person.
    tokio::time::sleep(std::time::Duration::from_millis(3)).await;
    w.store
        .suppress_link_previews(w.channel, id, w.moderator.1)
        .await
        .unwrap();

    assert!(listed_flag(&w).await.is_null());
    assert!(!op_flag(&w).await);
}
