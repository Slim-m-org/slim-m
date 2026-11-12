// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A channel overwrite write refused for granting bits the caller lacks names
//! those bits in the 403 body as `missing_permissions`.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use support::overwrite_harness::{app, general_channel_id, json_body, register, request};

async fn new_store() -> (slimm_server::store::Store, support::TestDbGuard) {
    support::overwrite_harness::new_store("slimm-overwrite-escalation-test").await
}

#[tokio::test]
async fn allow_cannot_grant_a_permission_the_caller_lacks() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (member_token, member_id) = register(&store, "bob").await;
    let channel_id = general_channel_id(&store).await;

    // Bob holds MANAGE_ROLES (via a role) but never BAN_MEMBERS.
    let manager_role = store
        .create_role("manager", Permissions::MANAGE_ROLES, false)
        .await
        .unwrap();
    store
        .assign_role(
            slimm_server::ids::UserId(Uuid::parse_str(&member_id).unwrap()),
            manager_role,
        )
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel_id}/overwrites/member/{member_id}"),
            Some(&member_token),
            Some(json!({ "allow": Permissions::BAN_MEMBERS.bits(), "deny": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let body = json_body(response).await;
    assert_eq!(
        body["missing_permissions"],
        Permissions::BAN_MEMBERS.bits(),
        "the refusal names the bit the caller cannot grant"
    );

    // The same admin-only token can, since ADMINISTRATOR resolves to ALL.
    let allowed = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel_id}/overwrites/member/{member_id}"),
            Some(&admin_token),
            Some(json!({ "allow": Permissions::BAN_MEMBERS.bits(), "deny": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(allowed.status(), StatusCode::NO_CONTENT);
}

/// Clearing a deny grants that permission just as surely as setting an allow.
/// Judging a write by its `allow` bits alone let a caller strip a deny and hand
/// themselves a bit they could never have granted directly.
#[tokio::test]
async fn clearing_a_deny_you_do_not_hold_is_refused() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());

    // First account claims the deployment and is its administrator.
    let (admin, _admin_id) = register(&store, "admin").await;
    let (moderator, moderator_id) = register(&store, "moderator").await;
    let channel = general_channel_id(&store).await;

    // The moderator may manage roles, but never gets MANAGE_SERVER.
    let role = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(&admin),
                Some(json!({
                    "name": "moderator",
                    "permissions": Permissions::VIEW_CHANNEL
                        .union(Permissions::MANAGE_ROLES)
                        .bits()
                })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let role_id = role["id"].as_str().unwrap().to_owned();
    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{moderator_id}/roles/{role_id}"),
            Some(&admin),
            None,
        ))
        .await
        .unwrap();

    // The administrator denies MANAGE_SERVER to that role in this channel.
    let overwrite = format!("/channels/{channel}/overwrites/role/{role_id}");
    let denied = app
        .clone()
        .oneshot(request(
            "PUT",
            &overwrite,
            Some(&admin),
            Some(json!({ "allow": 0, "deny": Permissions::MANAGE_SERVER.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::NO_CONTENT);

    // Dropping the deny would grant MANAGE_SERVER, which the moderator lacks.
    let rewrite = app
        .clone()
        .oneshot(request(
            "PUT",
            &overwrite,
            Some(&moderator),
            Some(json!({ "allow": 0, "deny": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(
        rewrite.status(),
        StatusCode::FORBIDDEN,
        "dropping a deny grants that bit, so it needs the same check setting an allow does"
    );
    assert_eq!(
        json_body(rewrite).await["missing_permissions"],
        Permissions::MANAGE_SERVER.bits()
    );

    // And deleting the overwrite outright must not be the way around it.
    let cleared = app
        .clone()
        .oneshot(request("DELETE", &overwrite, Some(&moderator), None))
        .await
        .unwrap();
    assert_eq!(
        cleared.status(),
        StatusCode::FORBIDDEN,
        "clearing an overwrite grants back everything it denied"
    );
    assert_eq!(
        json_body(cleared).await["missing_permissions"],
        Permissions::MANAGE_SERVER.bits()
    );
}
