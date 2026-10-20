// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An administrator replaces a bot's token: the old one dies at once, the new
//! one works, and the act is on the trail.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::harness::{admin, app, create_bot, harness, json_body, member, request};

async fn status_of(app: &axum::Router, token: &str, uri: &str) -> StatusCode {
    app.clone()
        .oneshot(request("GET", uri, token, None))
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn reissuing_kills_the_old_token_and_the_new_one_works() {
    let (store, pool, _guard) = harness("slimm-bot-reissue-swap").await;
    let (admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, old, _) = create_bot(&app, &root, "helper", Permissions::NONE.bits()).await;
    assert_eq!(status_of(&app, &old, "/me").await, StatusCode::OK);

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/bots/{bot_id}/token"),
            &root,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    let fresh = body["token"].as_str().unwrap().to_owned();
    assert_ne!(fresh, old);
    assert_eq!(body["bot"]["user_id"], bot_id.as_str());

    assert_eq!(status_of(&app, &old, "/me").await, StatusCode::UNAUTHORIZED);
    assert_eq!(status_of(&app, &fresh, "/me").await, StatusCode::OK);

    let actor: Vec<(Vec<u8>,)> = sqlx::query_as(
        "SELECT actor_id FROM moderation_audit_log
         WHERE subject_id = ? AND action = 'bot_token_reissue'",
    )
    .bind(UserId(bot_id.parse().unwrap()))
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(actor, vec![(admin_id.0.as_bytes().to_vec(),)]);
}

#[tokio::test]
async fn a_revoked_bot_gets_a_working_token_back() {
    let (store, _pool, _guard) = harness("slimm-bot-reissue-revoked").await;
    let (_admin, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, old, _) = create_bot(&app, &root, "helper", Permissions::NONE.bits()).await;
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/bots/{bot_id}/revoke"),
            &root,
            None,
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/bots/{bot_id}/token"),
            &root,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let fresh = json_body(response).await["token"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(status_of(&app, &old, "/me").await, StatusCode::UNAUTHORIZED);
    assert_eq!(status_of(&app, &fresh, "/me").await, StatusCode::OK);
}

#[tokio::test]
async fn only_an_administrator_may_reissue_and_not_a_removed_or_unknown_bot() {
    let (store, _pool, _guard) = harness("slimm-bot-reissue-refusals").await;
    let (admin_id, root) = admin(&store, "root").await;
    let (_member, plain) = member(&store, "dana").await;
    let app = app(store.clone());
    let (bot_id, bot_token, _) = create_bot(&app, &root, "helper", Permissions::NONE.bits()).await;
    let uri = format!("/bots/{bot_id}/token");

    for token in [&plain, &bot_token] {
        let denied = app
            .clone()
            .oneshot(request("POST", &uri, token, None))
            .await
            .unwrap();
        assert_eq!(denied.status(), StatusCode::FORBIDDEN);
    }
    let unknown = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/bots/{}/token", uuid::Uuid::now_v7()),
            &root,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(unknown.status(), StatusCode::NOT_FOUND);

    store
        .remove_from_space(UserId(bot_id.parse().unwrap()), admin_id, None)
        .await
        .unwrap();
    let removed = app
        .clone()
        .oneshot(request("POST", &uri, &root, Some(json!({}))))
        .await
        .unwrap();
    assert_eq!(removed.status(), StatusCode::CONFLICT);
}

/// A manager below the bot's role must not take over the bot's credentials.
#[tokio::test]
async fn a_weaker_caller_cannot_reissue_or_revoke_a_stronger_bot() {
    let (store, pool, _guard) = harness("slimm-bot-reissue-escalation").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_SERVER),
            true,
        )
        .await
        .unwrap();
    let (admin_id, root) = admin(&store, "root").await;
    assert!(
        !store
            .base_permissions(admin_id)
            .await
            .unwrap()
            .contains(Permissions::ADMINISTRATOR)
    );
    let app = app(store.clone());
    let (bot_id, old, _) = create_bot(&app, &root, "helper", 0).await;
    sqlx::query("UPDATE roles SET permissions = ? WHERE managed_bot_id = ?")
        .bind(Permissions::ADMINISTRATOR.bits())
        .bind(UserId(bot_id.parse().unwrap()))
        .execute(&pool)
        .await
        .unwrap();

    for path in ["token", "revoke"] {
        let denied = app
            .clone()
            .oneshot(request(
                "POST",
                &format!("/bots/{bot_id}/{path}"),
                &root,
                None,
            ))
            .await
            .unwrap();
        assert_eq!(denied.status(), StatusCode::FORBIDDEN, "{path}");
    }
    assert_eq!(status_of(&app, &old, "/me").await, StatusCode::OK);
}

#[tokio::test]
async fn a_module_principal_cannot_be_given_a_token() {
    let (store, pool, _guard) = harness("slimm-bot-reissue-module").await;
    let (_admin, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let id = UserId::generate();
    sqlx::query("INSERT INTO users (id, username, display_name, created_at, is_bot) VALUES (?, 'module-x', 'x', 0, 1)")
        .bind(id)
        .execute(&pool)
        .await
        .unwrap();
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/bots/{}/token", id.0),
            &root,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}
