// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every bot holds the shared Bots role; its own managed role exists only while it is
//! granted permissions. See `docs/decisions/0028-bot-accounts.md`.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use sqlx::SqlitePool;
use tower::ServiceExt;

use crate::harness::{admin, app, create_bot, harness, json_body, request};

async fn role_names_of(pool: &SqlitePool, user: UserId) -> Vec<String> {
    sqlx::query_scalar::<_, String>(
        "SELECT r.name FROM member_roles mr JOIN roles r ON r.id = mr.role_id
         WHERE mr.user_id = ? ORDER BY r.name",
    )
    .bind(user)
    .fetch_all(pool)
    .await
    .unwrap()
}

async fn bots_role_count(pool: &SqlitePool) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM roles WHERE is_bots_role = 1")
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn a_bot_with_no_permissions_gets_the_bots_role_and_no_managed_role() {
    let (store, pool, _guard) = harness("slimm-bot-shared-zero").await;
    let (_admin, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _, status) = create_bot(&app, &root, "helper", 0).await;
    assert_eq!(status, StatusCode::CREATED);
    let bot = UserId(bot_id.parse().unwrap());

    assert_eq!(role_names_of(&pool, bot).await, ["Bots"]);
    assert!(store.role_for_bot(bot).await.unwrap().is_none());
    let (second, _, _) = create_bot(&app, &root, "second", 0).await;
    let second = UserId(second.parse().unwrap());
    assert_eq!(role_names_of(&pool, second).await, ["Bots"]);
    assert_eq!(bots_role_count(&pool).await, 1);
}

#[tokio::test]
async fn a_bot_with_permissions_gets_both_roles() {
    let (store, pool, _guard) = harness("slimm-bot-shared-both").await;
    let (_admin, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _, _) = create_bot(&app, &root, "helper", Permissions::MANAGE_ROLES.bits()).await;
    let bot = UserId(bot_id.parse().unwrap());

    assert_eq!(role_names_of(&pool, bot).await, ["Bots", "helper"]);
    let managed = store.role_for_bot(bot).await.unwrap().unwrap();
    assert_eq!(managed.permissions, Permissions::MANAGE_ROLES);
}

async fn patch(
    app: &axum::Router,
    root: &str,
    bot_id: &str,
    bits: i64,
) -> (StatusCode, serde_json::Value) {
    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/bots/{bot_id}/permissions"),
            root,
            Some(json!({ "permissions": bits })),
        ))
        .await
        .unwrap();
    (response.status(), json_body(response).await)
}

#[tokio::test]
async fn patching_permissions_creates_then_removes_the_managed_role() {
    let (store, pool, _guard) = harness("slimm-bot-shared-patch").await;
    let (_admin, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _, _) = create_bot(&app, &root, "helper", 0).await;
    let bot = UserId(bot_id.parse().unwrap());

    let (status, body) = patch(&app, &root, &bot_id, Permissions::MANAGE_ROLES.bits()).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["role_id"].is_string());
    assert_eq!(body["permissions"], Permissions::MANAGE_ROLES.bits());
    assert_eq!(role_names_of(&pool, bot).await, ["Bots", "helper"]);

    let (status, body) = patch(&app, &root, &bot_id, 0).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["role_id"].is_null());
    assert_eq!(body["permissions"], 0);
    assert_eq!(role_names_of(&pool, bot).await, ["Bots"]);
    assert!(store.role_for_bot(bot).await.unwrap().is_none());

    let (status, _) = patch(&app, &root, &bot_id, 0).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn a_role_less_bot_can_be_reissued_and_revoked() {
    let (store, _pool, _guard) = harness("slimm-bot-shared-lifecycle").await;
    let (_admin, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _, _) = create_bot(&app, &root, "helper", 0).await;

    for (path, expected) in [
        ("token", StatusCode::OK),
        ("revoke", StatusCode::NO_CONTENT),
    ] {
        let response = app
            .clone()
            .oneshot(request(
                "POST",
                &format!("/bots/{bot_id}/{path}"),
                &root,
                None,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), expected, "{path}");
    }
}

#[tokio::test]
async fn a_weaker_caller_still_cannot_repermission_a_role_less_bot() {
    let (store, _pool, _guard) = harness("slimm-bot-shared-weaker").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_SERVER),
            true,
        )
        .await
        .unwrap();
    let (_admin, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _, _) = create_bot(&app, &root, "helper", 0).await;

    let (status, _) = patch(&app, &root, &bot_id, Permissions::ADMINISTRATOR.bits()).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_module_principal_is_still_not_a_bot() {
    let (store, pool, _guard) = harness("slimm-bot-shared-module").await;
    let (_admin, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let id = UserId::generate();
    sqlx::query("INSERT INTO users (id, username, display_name, created_at, is_bot) VALUES (?, 'module-x', 'x', 0, 1)")
        .bind(id)
        .execute(&pool)
        .await
        .unwrap();

    assert!(!store.is_bot_account(id).await.unwrap());
    let (status, _) = patch(
        &app,
        &root,
        &id.0.to_string(),
        Permissions::MANAGE_ROLES.bits(),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(role_names_of(&pool, id).await.is_empty());
}

#[tokio::test]
async fn the_bots_role_cannot_be_deleted_but_can_be_edited() {
    let (store, pool, _guard) = harness("slimm-bot-shared-delete").await;
    let (_admin, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (_bot_id, _, _) = create_bot(&app, &root, "helper", 0).await;
    let role: String =
        sqlx::query_scalar("SELECT lower(hex(id)) FROM roles WHERE is_bots_role = 1")
            .fetch_one(&pool)
            .await
            .unwrap();
    let id = uuid::Uuid::parse_str(&role).unwrap();

    let deleted = app
        .clone()
        .oneshot(request("DELETE", &format!("/roles/{id}"), &root, None))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::CONFLICT);
    assert_eq!(bots_role_count(&pool).await, 1);

    let edited = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/roles/{id}"),
            &root,
            Some(json!({ "permissions": Permissions::VIEW_CHANNEL.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(edited.status(), StatusCode::OK);

    let listed = app
        .clone()
        .oneshot(request("GET", "/roles", &root, None))
        .await
        .unwrap();
    let roles = json_body(listed).await;
    let bots = roles
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["is_bots_role"] == true)
        .unwrap();
    assert_eq!(bots["name"], "Bots");
}
