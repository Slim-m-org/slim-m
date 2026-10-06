// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The managed role is a convenience, not a ceiling: it is an ordinary role
//! an admin can edit, share or delete freely, and a bot's own lifecycle never
//! disturbs a human who also holds it. Plus the moderation-audit trail across
//! a bot's full lifecycle.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::harness::{admin, app, create_bot, harness, request};

/// A bot's managed role is an ordinary role, freely editable.
#[tokio::test]
async fn a_managed_role_can_be_edited_through_the_roles_route() {
    let (store, _pool, _guard) = harness("slimm-bot-perm-managed-editable").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _token, status) =
        create_bot(&app, &root, "helper", Permissions::MANAGE_ROLES.bits()).await;
    assert_eq!(status, StatusCode::CREATED);

    let bot = UserId(bot_id.parse().unwrap());
    let role = store.role_for_bot(bot).await.unwrap().unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/roles/{}", role.id),
            &root,
            Some(json!({ "name": "renamed" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

/// Revoking a bot leaves its managed role, and a human sharing it, untouched.
#[tokio::test]
async fn revoking_a_bot_leaves_its_managed_role_and_other_holders_intact() {
    let (store, _pool, _guard) = harness("slimm-bot-perm-revoke-keeps-role").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _token, status) =
        create_bot(&app, &root, "helper", Permissions::MANAGE_ROLES.bits()).await;
    assert_eq!(status, StatusCode::CREATED);
    let bot = UserId(bot_id.parse().unwrap());
    let role = store.role_for_bot(bot).await.unwrap().unwrap();

    let dana = store.create_user("dana", "Dana").await.unwrap();
    store.assign_role(dana.id, role.id).await.unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/bots/{bot_id}/revoke"),
            &root,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    assert!(store.role_for_bot(bot).await.unwrap().is_some());
    assert!(
        store
            .base_permissions(dana.id)
            .await
            .unwrap()
            .contains(Permissions::MANAGE_ROLES),
        "a human sharing the role must keep the grant after the bot is revoked"
    );
}

/// A failure while revoking the bot's sessions must leave the whole revoke retryable.
#[tokio::test]
async fn a_failed_revoke_can_be_retried_and_still_revokes_the_session() {
    let (store, pool, _guard) = harness("slimm-bot-perm-revoke-retry").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _token, status) =
        create_bot(&app, &root, "helper", Permissions::MANAGE_ROLES.bits()).await;
    assert_eq!(status, StatusCode::CREATED);
    let bot = UserId(bot_id.parse().unwrap());
    let revoke = || request("POST", &format!("/bots/{bot_id}/revoke"), &root, None);

    sqlx::query(
        "CREATE TRIGGER fault BEFORE UPDATE ON devices BEGIN SELECT RAISE(ABORT, 'injected'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    let first = app.clone().oneshot(revoke()).await.unwrap();
    assert_ne!(
        first.status(),
        StatusCode::NO_CONTENT,
        "sanity: the fault fires"
    );
    sqlx::query("DROP TRIGGER fault")
        .execute(&pool)
        .await
        .unwrap();

    let retry = app.clone().oneshot(revoke()).await.unwrap();
    assert_eq!(retry.status(), StatusCode::NO_CONTENT);
    let live: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sessions WHERE user_id = ? AND revoked_at IS NULL",
    )
    .bind(bot)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(
        live, 0,
        "after a successful retry the bot's session must be revoked"
    );
}

/// Decision 0028 promises bot creation, revocation, and permission changes
/// all land on the moderation-audit trail (decision 0015).
#[tokio::test]
async fn bot_lifecycle_and_permission_changes_reach_the_audit_trail() {
    let (store, pool, _guard) = harness("slimm-bot-perm-audit-trail").await;
    let (admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());

    let (bot_id, _token, status) =
        create_bot(&app, &root, "helper", Permissions::MANAGE_ROLES.bits()).await;
    assert_eq!(status, StatusCode::CREATED);
    let bot = UserId(bot_id.parse().unwrap());

    app.clone()
        .oneshot(request(
            "PATCH",
            &format!("/bots/{bot_id}/permissions"),
            &root,
            Some(json!({ "permissions": Permissions::SEND_MESSAGES.bits() })),
        ))
        .await
        .unwrap();

    app.clone()
        .oneshot(request(
            "POST",
            &format!("/bots/{bot_id}/revoke"),
            &root,
            None,
        ))
        .await
        .unwrap();

    let rows: Vec<(String, Option<Vec<u8>>)> = sqlx::query_as(
        "SELECT action, actor_id FROM moderation_audit_log
         WHERE subject_id = ? ORDER BY id",
    )
    .bind(bot)
    .fetch_all(&pool)
    .await
    .expect("read the moderation audit log");

    let actions: Vec<&str> = rows.iter().map(|(a, _)| a.as_str()).collect();
    assert_eq!(
        actions,
        vec!["bot_create", "bot_permission_grant", "bot_revoke"],
        "all three bot lifecycle acts must land on the trail, in order"
    );
    for (_, actor) in &rows {
        assert_eq!(
            actor.as_deref(),
            Some(admin_id.0.as_bytes().as_slice()),
            "the acting admin, not the bot itself, is the recorded actor"
        );
    }
}

/// Hard-deleting a bot's account detaches its managed role rather than
/// deleting it, so a human sharing the role keeps it.
#[tokio::test]
async fn deleting_a_bots_account_detaches_its_managed_role_without_deleting_it() {
    let (store, _pool, _guard) = harness("slimm-bot-perm-account-delete-detaches-role").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _token, status) =
        create_bot(&app, &root, "helper", Permissions::MANAGE_ROLES.bits()).await;
    assert_eq!(status, StatusCode::CREATED);
    let bot = UserId(bot_id.parse().unwrap());
    let role = store.role_for_bot(bot).await.unwrap().unwrap();

    let dana = store.create_user("dana", "Dana").await.unwrap();
    store.assign_role(dana.id, role.id).await.unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{bot_id}/account"),
            &root,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    assert!(
        store.role_for_bot(bot).await.unwrap().is_none(),
        "the tombstoned bot no longer names a managed role"
    );
    assert!(
        store
            .base_permissions(dana.id)
            .await
            .unwrap()
            .contains(Permissions::MANAGE_ROLES),
        "the role itself, and a human sharing it, must survive"
    );
}
