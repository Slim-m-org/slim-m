// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! PATCH /roles cannot strip ADMINISTRATOR from the deployment's only
//! administrator role, the same invariant delete and unassign keep
//! (issue 2057), unless the Space owner, who holds everything without it, remains.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use slimm_server::store::{RoleChanges, RoleGuardError, Store};
use tower::ServiceExt;

use crate::support;
use support::overwrite_harness::{app, new_store, register, request};

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

async fn patch(app: &axum::Router, token: &str, role: &str, permissions: i64) -> StatusCode {
    app.clone()
        .oneshot(request(
            "PATCH",
            &format!("/roles/{role}"),
            Some(token),
            Some(json!({ "permissions": permissions })),
        ))
        .await
        .unwrap()
        .status()
}

async fn still_administrator(store: &Store, role: &str) -> bool {
    store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.id.to_string() == role)
        .unwrap()
        .permissions
        .contains(Permissions::ADMINISTRATOR)
}

/// Nobody owns a Space that was never claimed, so the guard is what stands.
#[tokio::test]
async fn patching_the_only_admin_role_cannot_drop_administrator() {
    let (store, _guard) = new_store("slimm-role-patch-last-admin").await;
    let admin = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let alice = store.create_user("alice", "Alice").await.unwrap();
    store.assign_role(alice.id, admin).await.unwrap();

    for permissions in [Permissions::NONE, Permissions::MANAGE_ROLES] {
        let changes = RoleChanges {
            name: None,
            permissions: Some(permissions),
            mentionable: None,
            hoist: None,
            color: None,
        };
        let refused = store.update_role(admin, changes).await;
        assert!(matches!(refused, Err(RoleGuardError::LastAdministrator)));
    }
    assert!(still_administrator(&store, &admin.to_string()).await);
}

#[tokio::test]
async fn the_owner_may_drop_administrator_from_the_only_admin_role() {
    let (store, _guard) = new_store("slimm-role-patch-owner").await;
    let (owner, owner_id) = register(&store, "alice").await;
    let app = app(store.clone());
    let role = admin_role_id(&store).await;

    assert_eq!(patch(&app, &owner, &role, 0).await, StatusCode::OK);
    assert!(!still_administrator(&store, &role).await);
    let owner_id = slimm_server::ids::UserId(owner_id.parse().unwrap());
    let held = store.base_permissions(owner_id).await.unwrap();
    assert_eq!(held, Permissions::ALL);
}

#[tokio::test]
async fn a_second_admin_role_lets_the_first_be_patched() {
    let (store, _guard) = new_store("slimm-role-patch-second-admin").await;
    let (admin, admin_id) = register(&store, "alice").await;
    let app = app(store.clone());
    let role = admin_role_id(&store).await;
    let backup = store
        .create_role("backup", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    store
        .assign_role(slimm_server::ids::UserId(admin_id.parse().unwrap()), backup)
        .await
        .unwrap();

    assert_eq!(patch(&app, &admin, &role, 0).await, StatusCode::OK);
    assert!(!still_administrator(&store, &role).await);
}

/// Removing the assignment or the role keeps the same guard where nobody owns the Space.
#[tokio::test]
async fn unassigning_or_deleting_the_only_admin_role_is_refused_without_an_owner() {
    let (store, _guard) = new_store("slimm-role-delete-last-admin").await;
    let admin = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let alice = store.create_user("alice", "Alice").await.unwrap();
    store.assign_role(alice.id, admin).await.unwrap();

    let unassigned = store.unassign_role(alice.id, admin).await;
    assert!(matches!(unassigned, Err(RoleGuardError::LastAdministrator)));
    let deleted = store.delete_role(admin).await;
    assert!(matches!(deleted, Err(RoleGuardError::LastAdministrator)));
    assert!(store.holds_role(alice.id, admin).await.unwrap());
}
