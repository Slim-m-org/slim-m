// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot's declared permissions: the same no-escalation guard a
//! human-assigned role goes through, and full parity with a human otherwise.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::bot_permissioning::harness::{
    admin, app, create_bot, harness, json_body, member, request,
};

/// An admin may grant a bot only bits they hold themselves.
#[tokio::test]
async fn creating_a_bot_cannot_grant_a_permission_the_caller_lacks() {
    let (store, _pool, _guard) = harness("slimm-bot-perm-create-escalation").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_ROLES),
            true,
        )
        .await
        .unwrap();
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());

    // MANAGE_MESSAGES is not something `root` holds here (only `@everyone`).
    let (_, _, status) =
        create_bot(&app, &root, "helper", Permissions::MANAGE_MESSAGES.bits()).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

/// The mutation this guard exists for: a caller who genuinely holds a bit can
/// grant exactly it, and the grant actually takes effect.
#[tokio::test]
async fn creating_a_bot_can_grant_a_permission_the_caller_holds() {
    let (store, _pool, _guard) = harness("slimm-bot-perm-create-ok").await;
    let (admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());

    let (bot_id, _token, status) =
        create_bot(&app, &root, "helper", Permissions::MANAGE_ROLES.bits()).await;
    assert_eq!(status, StatusCode::CREATED);

    let bot = UserId(bot_id.parse().unwrap());
    let granted = store.base_permissions(bot).await.unwrap();
    assert!(granted.contains(Permissions::MANAGE_ROLES));

    let admin_granted = store.base_permissions(admin_id).await.unwrap();
    assert!(
        admin_granted.contains(Permissions::MANAGE_ROLES),
        "the fixture's own claim: root actually holds what it just granted"
    );
}

/// Owner policy: a bot may hold any permission a human role could, including
/// ADMINISTRATOR, as long as the caller holds it too.
#[tokio::test]
async fn a_bot_can_be_created_with_administrator_when_the_caller_holds_it() {
    let (store, _pool, _guard) = harness("slimm-bot-perm-admin-create-ok").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());

    let (bot_id, _token, status) =
        create_bot(&app, &root, "helper", Permissions::ADMINISTRATOR.bits()).await;
    assert_eq!(status, StatusCode::CREATED);

    let bot = UserId(bot_id.parse().unwrap());
    assert!(
        store
            .base_permissions(bot)
            .await
            .unwrap()
            .contains(Permissions::ADMINISTRATOR)
    );
}

/// Full parity: an ADMINISTRATOR bot reaches a human-credential route exactly
/// like an administrator, since its power comes from its roles alone.
#[tokio::test]
async fn an_administrator_bot_can_issue_a_reset_code() {
    let (store, _pool, _guard) = harness("slimm-bot-perm-admin-parity-reset").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let (target_id, _target_token) = member(&store, "victim").await;
    let app = app(store.clone());

    let (_bot_id, bot_token, status) =
        create_bot(&app, &root, "helper", Permissions::ADMINISTRATOR.bits()).await;
    assert_eq!(status, StatusCode::CREATED);

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/admin/users/{target_id}/reset-code"),
            &bot_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

/// The same escalation guard, exercised on the repermission route rather than
/// creation, against a caller who provably does not hold ADMINISTRATOR (which
/// resolves to every bit and would make this vacuous - see
/// `store::bootstrap::bootstrap_deployment`).
#[tokio::test]
async fn repermissioning_a_bot_cannot_grant_a_permission_the_caller_lacks() {
    let (store, _pool, _guard) = harness("slimm-bot-perm-patch-escalation").await;
    // Claims `@everyone` first; see this test's own doc comment for why.
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
            .contains(Permissions::ADMINISTRATOR),
        "the fixture's own claim: root must not hold ADMINISTRATOR here"
    );
    let app = app(store.clone());
    let (bot_id, _token, status) = create_bot(&app, &root, "helper", 0).await;
    assert_eq!(status, StatusCode::CREATED);

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/bots/{bot_id}/permissions"),
            &root,
            Some(json!({ "permissions": Permissions::MANAGE_MESSAGES.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);

    let bot = UserId(bot_id.parse().unwrap());
    assert!(
        !store
            .base_permissions(bot)
            .await
            .unwrap()
            .contains(Permissions::MANAGE_MESSAGES),
        "a refused grant must not have taken effect"
    );
}

/// The positive side: a caller who holds the bit can grant it - the fix the
/// roles bot in production actually needed.
#[tokio::test]
async fn repermissioning_a_bot_can_grant_a_permission_the_caller_holds() {
    let (store, _pool, _guard) = harness("slimm-bot-perm-patch-ok").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _token, status) = create_bot(&app, &root, "helper", 0).await;
    assert_eq!(status, StatusCode::CREATED);

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/bots/{bot_id}/permissions"),
            &root,
            Some(json!({ "permissions": Permissions::MANAGE_ROLES.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["permissions"], Permissions::MANAGE_ROLES.bits());

    let bot = UserId(bot_id.parse().unwrap());
    assert!(
        store
            .base_permissions(bot)
            .await
            .unwrap()
            .contains(Permissions::MANAGE_ROLES)
    );
}

/// An ADMINISTRATOR-carrying role can be assigned to a bot through the
/// ordinary role-assignment route, same as to a human.
#[tokio::test]
async fn an_administrator_role_can_be_assigned_to_a_bot() {
    let (store, _pool, _guard) = harness("slimm-bot-perm-admin-assign-ok").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _token, status) = create_bot(&app, &root, "helper", 0).await;
    assert_eq!(status, StatusCode::CREATED);

    let role_id = store
        .list_roles()
        .await
        .unwrap()
        .iter()
        .find(|r| r.permissions.contains(Permissions::ADMINISTRATOR) && !r.is_everyone)
        .expect("bootstrap_deployment creates an administrator role")
        .id;

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bot_id}/roles/{role_id}"),
            &root,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let bot = UserId(bot_id.parse().unwrap());
    assert!(
        store
            .base_permissions(bot)
            .await
            .unwrap()
            .contains(Permissions::ADMINISTRATOR)
    );
}

/// A plain member cannot reach the repermission route.
#[tokio::test]
async fn an_ordinary_member_cannot_repermission_a_bot() {
    let (store, _pool, _guard) = harness("slimm-bot-perm-member-forbidden").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let (_member_id, member_token) = member(&store, "mallory").await;
    let app = app(store.clone());
    let (bot_id, _token, status) = create_bot(&app, &root, "helper", 0).await;
    assert_eq!(status, StatusCode::CREATED);

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/bots/{bot_id}/permissions"),
            &member_token,
            Some(json!({ "permissions": Permissions::SEND_MESSAGES.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}
