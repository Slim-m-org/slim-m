// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Role management and member role assignment: the MANAGE_ROLES gate, the
//! escalation guard (nobody can grant a permission they do not themselves
//! hold), and the invariant that the deployment never ends up with zero
//! administrators.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, register_token_id as register, request};

async fn admin_role_id(store: &Store) -> String {
    store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .expect("bootstrap seeds an admin role")
        .id
        .to_string()
}

// --- The MANAGE_ROLES gate ---

/// Every role-management verb refuses a caller without MANAGE_ROLES, whether
/// or not the resource named in the path exists.
#[tokio::test]
async fn every_verb_requires_manage_roles() {
    let (store, _guard) = support::new_store("slimm-roles-test").await;
    let app = app(store.clone());
    let (_admin_token, _admin_id) = register(&store, "alice").await;
    let (member_token, member_id) = register(&store, "bob").await;
    let admin_role = admin_role_id(&store).await;

    let cases: [(&str, String); 6] = [
        ("GET", "/roles".to_owned()),
        ("POST", "/roles".to_owned()),
        ("PATCH", format!("/roles/{admin_role}")),
        ("DELETE", format!("/roles/{admin_role}")),
        ("PUT", format!("/members/{member_id}/roles/{admin_role}")),
        ("DELETE", format!("/members/{member_id}/roles/{admin_role}")),
    ];
    for (method, uri) in cases {
        let body =
            matches!(method, "POST" | "PATCH").then(|| json!({ "name": "x", "permissions": 0 }));
        let response = app
            .clone()
            .oneshot(request(method, &uri, Some(&member_token), body))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::FORBIDDEN,
            "{method} {uri} must require MANAGE_ROLES"
        );
    }
}

// --- Escalation: nobody can grant what they do not hold ---

/// A MANAGE_ROLES holder who is not themselves an administrator cannot create
/// a role carrying ADMINISTRATOR: MANAGE_ROLES is not a shortcut to it.
#[tokio::test]
async fn creating_a_role_cannot_grant_a_permission_the_caller_lacks() {
    let (store, _guard) = support::new_store("slimm-roles-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (member_token, member_id) = register(&store, "bob").await;

    let manager_role = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(&admin_token),
                Some(json!({ "name": "manager", "permissions": Permissions::MANAGE_ROLES.bits() })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let manager_role_id = manager_role["id"].as_str().unwrap();
    let assign = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{member_id}/roles/{manager_role_id}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(assign.status(), StatusCode::NO_CONTENT);

    // Bob now holds MANAGE_ROLES but nothing else. He must not be able to
    // mint an administrator role, not even for himself.
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/roles",
            Some(&member_token),
            Some(json!({
                "name": "self-promotion",
                "permissions": Permissions::ADMINISTRATOR.bits()
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// Assigning an existing role is also a grant: a MANAGE_ROLES holder cannot
/// hand out the `admin` role to themselves or anyone else unless they already
/// hold ADMINISTRATOR.
#[tokio::test]
async fn assigning_a_role_cannot_grant_a_permission_the_caller_lacks() {
    let (store, _guard) = support::new_store("slimm-roles-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (member_token, member_id) = register(&store, "bob").await;
    let admin_role = admin_role_id(&store).await;

    let manager_role = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(&admin_token),
                Some(json!({ "name": "manager", "permissions": Permissions::MANAGE_ROLES.bits() })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let manager_role_id = manager_role["id"].as_str().unwrap().to_owned();
    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{member_id}/roles/{manager_role_id}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{member_id}/roles/{admin_role}"),
            Some(&member_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// Unknown permission bits are rejected outright, before the escalation
/// check even runs, so a stray high bit cannot smuggle in a future meaning.
#[tokio::test]
async fn unknown_permission_bits_are_rejected() {
    let (store, _guard) = support::new_store("slimm-roles-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/roles",
            Some(&admin_token),
            Some(json!({ "name": "weird", "permissions": 1_i64 << 60 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

// See tests/role_escalation.rs: unassign/update/delete above your level.

// --- The last-administrator invariant ---

/// The sole administrator cannot remove their own admin role: that would
/// leave the deployment with no administrator and no recovery path.
#[tokio::test]
async fn cannot_unassign_the_last_administrator() {
    let (store, _guard) = support::new_store("slimm-roles-test").await;
    let app = app(store.clone());
    let (admin_token, admin_id) = register(&store, "alice").await;
    let admin_role = admin_role_id(&store).await;

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{admin_id}/roles/{admin_role}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);

    // The refusal must be a real rollback: alice is still an administrator
    // and can still do administrator-only things afterwards.
    let still_admin = app
        .clone()
        .oneshot(request(
            "POST",
            "/roles",
            Some(&admin_token),
            Some(json!({ "name": "proof", "permissions": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(still_admin.status(), StatusCode::OK);
}

/// Deleting the role that is the deployment's only source of ADMINISTRATOR is
/// refused the same way removing the assignment is, even for the
/// administrator doing it themselves - the escalation guard cannot be what
/// refuses this, since an administrator's granted set already contains
/// whatever the role carries, so it has to be the structural invariant.
///
/// A MANAGE_ROLES holder who is not themselves an administrator is refused
/// earlier and for a different reason now: see
/// `only_the_administrators_own_bits_let_them_touch_an_administrator_role`,
/// which pins that as 403 rather than 409 and proves it is not this test in
/// disguise by leaving a second administrator role in place.
#[tokio::test]
async fn cannot_delete_the_only_administrator_role() {
    let (store, _guard) = support::new_store("slimm-roles-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let admin_role = admin_role_id(&store).await;

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/roles/{admin_role}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
}

/// Once a second administrator exists, removing the first one's assignment
/// succeeds: the guard only refuses the transition to zero, not to one.
#[tokio::test]
async fn a_second_administrator_makes_removal_possible() {
    let (store, _guard) = support::new_store("slimm-roles-test").await;
    let app = app(store.clone());
    let (admin_token, admin_id) = register(&store, "alice").await;
    let (_member_token, member_id) = register(&store, "bob").await;
    let admin_role = admin_role_id(&store).await;

    let promote = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{member_id}/roles/{admin_role}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(promote.status(), StatusCode::NO_CONTENT);

    let demote_self = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{admin_id}/roles/{admin_role}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(demote_self.status(), StatusCode::NO_CONTENT);
}

/// `@everyone` can never be deleted, administrator or not: it is the base of
/// every permission evaluation and the schema allows only one.
#[tokio::test]
async fn cannot_delete_everyone_role() {
    let (store, _guard) = support::new_store("slimm-roles-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;

    let everyone_id = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .expect("bootstrap seeds @everyone")
        .id
        .to_string();

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/roles/{everyone_id}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
}

// --- Happy path ---

#[tokio::test]
async fn admin_can_create_update_list_and_the_role_takes_effect() {
    let (store, _guard) = support::new_store("slimm-roles-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;

    let created = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(&admin_token),
                Some(json!({ "name": "mods", "permissions": Permissions::MANAGE_MESSAGES.bits() })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let role_id = created["id"].as_str().unwrap().to_owned();
    assert_eq!(created["name"], "mods");
    assert_eq!(created["is_everyone"], false);
    // Not requested at creation, so it starts off like every other role.
    assert_eq!(created["mentionable"], false);

    let updated = json_body(
        app.clone()
            .oneshot(request(
                "PATCH",
                &format!("/roles/{role_id}"),
                Some(&admin_token),
                Some(json!({ "name": "moderators" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(updated["name"], "moderators");
    // Untouched field survives a partial update.
    assert_eq!(updated["permissions"], Permissions::MANAGE_MESSAGES.bits());

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/roles", Some(&admin_token), None))
            .await
            .unwrap(),
    )
    .await;
    assert!(
        listed
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["id"] == role_id && r["name"] == "moderators")
    );
}
