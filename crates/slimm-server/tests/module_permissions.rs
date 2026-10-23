// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The dynamic permission surface: a module's declared permissions appear as
//! grantable rows, a role's grant of one round-trips over HTTP, and
//! `Store::user_has_module_permission` resolves correctly for both a granted
//! and an ungranted user. See docs/decisions/0021-modules-and-the-dock.md.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::permissions::Permissions;
use slimm_server::store::{
    InstallModuleRequest, ModulePermissionSpec, ModuleRuntimeLimits, Store, User,
};
use tower::ServiceExt;

mod support;

use support::app::{app, json_body};

async fn store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

async fn deployment(s: &Store) -> (User, User) {
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    s.create_role("everyone", view_send, true).await.unwrap();
    let admin_role = s
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = s.create_user("root", "Root").await.unwrap();
    s.assign_role(admin.id, admin_role).await.unwrap();
    let member = s.create_user("nia", "Nia").await.unwrap();
    (admin, member)
}

async fn install_code_exec(s: &Store) {
    let permissions = vec![ModulePermissionSpec {
        key: "run",
        name: "Execute code blocks",
        description: "run a snippet",
    }];
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "code-exec",
            name: "Code Blocks",
            version: "0.1.0",
            artifact_sha256: &"0".repeat(64),
            approved_capabilities: &["command.register".to_owned()],
            runtime_limits: &ModuleRuntimeLimits::default(),
            permissions: &permissions,
            extension_points: &[],
        },
        b"stub-artifact",
    )
    .await
    .unwrap();
}

fn req(method: &str, uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

#[tokio::test]
async fn a_granted_role_makes_user_has_module_permission_true_and_others_false() {
    let (s, _guard) = store("slimm-module-perm-grant-check").await;
    install_code_exec(&s).await;

    let role = s
        .create_role("coders", Permissions::NONE, false)
        .await
        .unwrap();
    let granted_user = s.create_user("alice", "Alice").await.unwrap();
    let ungranted_user = s.create_user("bob", "Bob").await.unwrap();
    s.assign_role(granted_user.id, role).await.unwrap();

    assert!(
        !s.user_has_module_permission(granted_user.id, "code-exec", "run")
            .await
            .unwrap(),
        "not granted yet"
    );

    s.grant_module_permission(role, "code-exec", "run")
        .await
        .unwrap();

    assert!(
        s.user_has_module_permission(granted_user.id, "code-exec", "run")
            .await
            .unwrap()
    );
    assert!(
        !s.user_has_module_permission(ungranted_user.id, "code-exec", "run")
            .await
            .unwrap()
    );

    s.revoke_module_permission(role, "code-exec", "run")
        .await
        .unwrap();
    assert!(
        !s.user_has_module_permission(granted_user.id, "code-exec", "run")
            .await
            .unwrap(),
        "revoke removes it"
    );
}

#[tokio::test]
async fn granting_an_unknown_module_permission_is_refused() {
    let (s, _guard) = store("slimm-module-perm-unknown").await;
    let role = s
        .create_role("coders", Permissions::NONE, false)
        .await
        .unwrap();
    let outcome = s
        .grant_module_permission(role, "no-such-module", "run")
        .await;
    assert!(matches!(
        outcome,
        Err(slimm_server::store::GrantModulePermissionError::UnknownPermission)
    ));
}

#[tokio::test]
async fn uninstalling_a_module_cascades_its_grants_away() {
    let (s, _guard) = store("slimm-module-perm-cascade").await;
    install_code_exec(&s).await;
    let role = s
        .create_role("coders", Permissions::NONE, false)
        .await
        .unwrap();
    let user = s.create_user("alice", "Alice").await.unwrap();
    s.assign_role(user.id, role).await.unwrap();
    s.grant_module_permission(role, "code-exec", "run")
        .await
        .unwrap();
    assert!(
        s.user_has_module_permission(user.id, "code-exec", "run")
            .await
            .unwrap()
    );

    s.uninstall_module("code-exec").await.unwrap();

    assert!(
        !s.user_has_module_permission(user.id, "code-exec", "run")
            .await
            .unwrap(),
        "uninstall must cascade the grant away with the permission it granted"
    );
    assert!(s.role_module_permissions(role).await.unwrap().is_empty());
}

#[tokio::test]
async fn module_permissions_round_trip_over_the_roles_api() {
    let (s, _guard) = store("slimm-module-perm-http").await;
    let (admin, member) = deployment(&s).await;
    install_code_exec(&s).await;
    let role = s
        .create_role("coders", Permissions::NONE, false)
        .await
        .unwrap();

    let admin_session = s.open_session(admin.id, "laptop").await.unwrap();
    let admin_token = admin_session.access_token.as_str();
    let member_session = s.open_session(member.id, "phone").await.unwrap();
    let member_token = member_session.access_token.as_str();

    let router = app(s);

    // MANAGE_ROLES is required, the same gate every other roles.rs mutation uses.
    let forbidden = router
        .clone()
        .oneshot(req("GET", "/roles/module-permissions", member_token))
        .await
        .unwrap();
    assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);

    let catalog_response = router
        .clone()
        .oneshot(req("GET", "/roles/module-permissions", admin_token))
        .await
        .unwrap();
    assert_eq!(catalog_response.status(), StatusCode::OK);
    let catalog = json_body(catalog_response).await;
    let catalog = catalog.as_array().unwrap();
    assert_eq!(catalog.len(), 1);
    assert_eq!(catalog[0]["module_id"], json!("code-exec"));
    assert_eq!(catalog[0]["perm_key"], json!("run"));

    let grant_uri = format!("/roles/{role}/module-permissions/code-exec/run");
    let grant_response = router
        .clone()
        .oneshot(req("PUT", &grant_uri, admin_token))
        .await
        .unwrap();
    assert_eq!(grant_response.status(), StatusCode::NO_CONTENT);

    let grants_response = router
        .clone()
        .oneshot(req(
            "GET",
            &format!("/roles/{role}/module-permissions"),
            admin_token,
        ))
        .await
        .unwrap();
    let grants = json_body(grants_response).await;
    let grants = grants.as_array().unwrap();
    assert_eq!(grants.len(), 1);
    assert_eq!(grants[0]["perm_key"], json!("run"));

    let revoke_response = router
        .oneshot(req("DELETE", &grant_uri, admin_token))
        .await
        .unwrap();
    assert_eq!(revoke_response.status(), StatusCode::NO_CONTENT);
}

/// Roles ordered top, senior, junior; a member who holds only `senior`, which has MANAGE_ROLES.
struct Ladder {
    top: slimm_server::ids::RoleId,
    senior: slimm_server::ids::RoleId,
    junior: slimm_server::ids::RoleId,
    manager_token: String,
    admin_token: String,
}

async fn ladder(s: &Store) -> Ladder {
    let (admin, _member) = deployment(s).await;
    install_code_exec(s).await;
    let top = s
        .create_role("top", Permissions::NONE, false)
        .await
        .unwrap();
    let senior = s
        .create_role("senior", Permissions::MANAGE_ROLES, false)
        .await
        .unwrap();
    let junior = s
        .create_role("junior", Permissions::NONE, false)
        .await
        .unwrap();
    let admin_role = s
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .unwrap()
        .id;
    s.reorder_roles(&[admin_role, top, senior, junior])
        .await
        .unwrap();
    let manager = s.create_user("max", "Max").await.unwrap();
    s.assign_role(manager.id, senior).await.unwrap();
    Ladder {
        top,
        senior,
        junior,
        manager_token: s.open_session(manager.id, "pc").await.unwrap().access_token,
        admin_token: s.open_session(admin.id, "pc").await.unwrap().access_token,
    }
}

fn uri(role: slimm_server::ids::RoleId) -> String {
    format!("/roles/{role}/module-permissions/code-exec/run")
}

async fn status(
    router: &axum::Router,
    method: &str,
    role: slimm_server::ids::RoleId,
    token: &str,
) -> StatusCode {
    router
        .clone()
        .oneshot(req(method, &uri(role), token))
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn manage_roles_alone_cannot_grant_or_revoke_a_module_permission_it_lacks() {
    let (s, _guard) = store("slimm-module-perm-lacks").await;
    let l = ladder(&s).await;
    s.grant_module_permission(l.junior, "code-exec", "run")
        .await
        .unwrap();
    let router = app(s.clone());

    assert_eq!(
        status(&router, "PUT", l.junior, &l.manager_token).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        status(&router, "DELETE", l.junior, &l.manager_token).await,
        StatusCode::FORBIDDEN
    );
    let still_granted = s.role_module_permissions(l.junior).await.unwrap();
    assert_eq!(still_granted.len(), 1, "the refused revoke changed nothing");
}

#[tokio::test]
async fn a_manager_can_change_only_roles_below_their_own_and_only_permissions_they_hold() {
    let (s, _guard) = store("slimm-module-perm-hierarchy").await;
    let l = ladder(&s).await;
    s.grant_module_permission(l.senior, "code-exec", "run")
        .await
        .unwrap();
    let router = app(s.clone());

    assert_eq!(
        status(&router, "PUT", l.top, &l.manager_token).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        status(&router, "PUT", l.senior, &l.manager_token).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        status(&router, "PUT", l.junior, &l.manager_token).await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(s.role_module_permissions(l.junior).await.unwrap().len(), 1);
    assert_eq!(
        status(&router, "DELETE", l.junior, &l.manager_token).await,
        StatusCode::NO_CONTENT
    );
    assert!(
        s.role_module_permissions(l.junior)
            .await
            .unwrap()
            .is_empty()
    );

    s.grant_module_permission(l.top, "code-exec", "run")
        .await
        .unwrap();
    assert_eq!(
        status(&router, "DELETE", l.top, &l.manager_token).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(s.role_module_permissions(l.top).await.unwrap().len(), 1);
}

#[tokio::test]
async fn an_administrator_can_change_any_role_without_holding_the_permission() {
    let (s, _guard) = store("slimm-module-perm-admin").await;
    let l = ladder(&s).await;
    let router = app(s.clone());

    for role in [l.top, l.senior, l.junior] {
        assert_eq!(
            status(&router, "PUT", role, &l.admin_token).await,
            StatusCode::NO_CONTENT
        );
    }
    for role in [l.top, l.senior, l.junior] {
        assert_eq!(
            status(&router, "DELETE", role, &l.admin_token).await,
            StatusCode::NO_CONTENT
        );
    }
}
