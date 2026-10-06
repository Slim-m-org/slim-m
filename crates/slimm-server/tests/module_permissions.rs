// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The dynamic permission surface: a module's declared permissions appear as
//! grantable rows, a role's grant of one round-trips over HTTP, and
//! `Store::user_has_module_permission` resolves correctly for both a granted
//! and an ungranted user. See docs/decisions/0021-modules-and-the-dock.md.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{
    InstallModuleRequest, ModulePermissionSpec, ModuleRuntimeLimits, Store, User,
};
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

mod support;

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

fn app(store: Store) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: VoiceService::disabled(),
        media: Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
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

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
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
