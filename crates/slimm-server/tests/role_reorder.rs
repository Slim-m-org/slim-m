// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `PATCH /roles/reorder`: the live set must match exactly, a successful
//! reorder reports the new positions, and a caller may only touch a role
//! whose old or new position sits below their own highest held role -
//! `http::role_reorder`'s position-hierarchy guard, mirroring
//! `role_escalation.rs`'s bit-based tests for the same shape of rule.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, register_token_id as register, request};

async fn create_role(app: &Router, token: &str, name: &str, permissions: i64) -> String {
    let role = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(token),
                Some(json!({ "name": name, "permissions": permissions })),
            ))
            .await
            .unwrap(),
    )
    .await;
    role["id"].as_str().unwrap().to_owned()
}

async fn assign(app: &Router, admin_token: &str, user_id: &str, role_id: &str) {
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{user_id}/roles/{role_id}"),
            Some(admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}

async fn reorder(app: &Router, token: &str, role_ids: &[&str]) -> axum::response::Response {
    app.clone()
        .oneshot(request(
            "PATCH",
            "/roles/reorder",
            Some(token),
            Some(json!({ "role_ids": role_ids })),
        ))
        .await
        .unwrap()
}

/// A successful reorder puts the first id on top with the highest position
/// and reports every role's new `position`, matching what the pane's list
/// (highest first) needs to render.
#[tokio::test]
async fn reorder_reports_the_new_positions_in_order() {
    let (store, _guard) = support::new_store("slimm-role-reorder-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;

    let low = create_role(&app, &admin_token, "low", 0).await;
    let mid = create_role(&app, &admin_token, "mid", 0).await;
    let high = create_role(&app, &admin_token, "high", 0).await;
    let admin_role = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .unwrap()
        .id
        .to_string();

    let response = reorder(&app, &admin_token, &[&admin_role, &high, &mid, &low]).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    let roles = body.as_array().unwrap();

    let position = |id: &str| -> i64 {
        roles.iter().find(|r| r["id"] == id).unwrap()["position"]
            .as_i64()
            .unwrap()
    };
    assert!(position(&high) > position(&mid));
    assert!(position(&mid) > position(&low));
}

/// Every role, including `admin` (a live role created at bootstrap), must be
/// present exactly once; leaving one out is refused as a mismatch rather than
/// silently reordering a subset.
#[tokio::test]
async fn reorder_refuses_a_set_missing_a_live_role() {
    let (store, _guard) = support::new_store("slimm-role-reorder-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let extra = create_role(&app, &admin_token, "extra", 0).await;

    // Missing "admin" from the request.
    let response = reorder(&app, &admin_token, &[&extra]).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// `@everyone` never reorders: naming it is refused the same way an unknown
/// id is.
#[tokio::test]
async fn reorder_refuses_naming_everyone() {
    let (store, _guard) = support::new_store("slimm-role-reorder-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let everyone = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .unwrap()
        .id
        .to_string();
    let admin_role = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .unwrap()
        .id
        .to_string();

    let response = reorder(&app, &admin_token, &[&admin_role, &everyone]).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// A MANAGE_ROLES holder with no elevated role of their own cannot move
/// `admin` at all: its old position already sits at or above their ceiling
/// (which is zero, since they hold nothing beyond `@everyone`).
#[tokio::test]
async fn cannot_move_a_role_at_or_above_the_callers_own_ceiling() {
    let (store, _guard) = support::new_store("slimm-role-reorder-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    let manager_role = create_role(
        &app,
        &admin_token,
        "manager",
        Permissions::MANAGE_ROLES.bits(),
    )
    .await;
    assign(&app, &admin_token, &bob_id, &manager_role).await;

    let admin_role = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .unwrap()
        .id
        .to_string();

    // bob only reorders the two roles that exist beyond `@everyone`.
    let response = reorder(&app, &bob_token, &[&admin_role, &manager_role]).await;
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// The same caller *can* rearrange roles that are all strictly below their
/// own ceiling - the guard refuses reaching upward, not reordering at all.
#[tokio::test]
async fn can_reorder_roles_strictly_below_the_callers_own_ceiling() {
    let (store, _guard) = support::new_store("slimm-role-reorder-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    let manager_role = create_role(
        &app,
        &admin_token,
        "manager",
        Permissions::MANAGE_ROLES.bits(),
    )
    .await;
    assign(&app, &admin_token, &bob_id, &manager_role).await;

    let junior_a = create_role(&app, &admin_token, "junior-a", 0).await;
    let junior_b = create_role(&app, &admin_token, "junior-b", 0).await;

    // Puts the two junior roles below manager's position, so bob's ceiling sits above both.
    let admin_role = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .unwrap()
        .id
        .to_string();
    let setup = reorder(
        &app,
        &admin_token,
        &[&admin_role, &manager_role, &junior_a, &junior_b],
    )
    .await;
    assert_eq!(setup.status(), StatusCode::OK);

    // The full live set is still required; only the two roles below bob's ceiling actually move.
    let response = reorder(
        &app,
        &bob_token,
        &[&admin_role, &manager_role, &junior_b, &junior_a],
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
}

/// An administrator bypasses the ceiling entirely, the same way
/// ADMINISTRATOR already contains every bit `escalation_guard` compares.
#[tokio::test]
async fn an_administrator_bypasses_the_position_ceiling() {
    let (store, _guard) = support::new_store("slimm-role-reorder-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;

    let low = create_role(&app, &admin_token, "low", 0).await;
    let admin_role = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .unwrap()
        .id
        .to_string();

    let response = reorder(&app, &admin_token, &[&low, &admin_role]).await;
    assert_eq!(response.status(), StatusCode::OK);
}
