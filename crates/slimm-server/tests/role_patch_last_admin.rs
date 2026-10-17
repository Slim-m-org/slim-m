// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! PATCH /roles cannot strip ADMINISTRATOR from the deployment's only
//! administrator role, the same invariant delete and unassign keep
//! (issue 2057).

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;
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

#[tokio::test]
async fn patching_the_only_admin_role_cannot_drop_administrator() {
    let (store, _guard) = new_store("slimm-role-patch-last-admin").await;
    let (admin, _) = register(&store, "alice").await;
    let app = app(store.clone());
    let role = admin_role_id(&store).await;

    assert_eq!(patch(&app, &admin, &role, 0).await, StatusCode::CONFLICT);
    let manage_roles_only = Permissions::MANAGE_ROLES.bits();
    assert_eq!(
        patch(&app, &admin, &role, manage_roles_only).await,
        StatusCode::CONFLICT
    );
    assert!(still_administrator(&store, &role).await);
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
