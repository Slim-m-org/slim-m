// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Apps: launching an installed module's `app` extension point as a message,
//! and discovering which apps a caller may launch. Covers the discovery filter
//! (installed, enabled, permission held), the launch's message-plus-surface
//! shape, its idempotency, and the two gates - the per-channel send permission
//! and the module permission - that a launch must clear.
//!
//! `tests/module_commands.rs` covers running a command; this file is only about
//! launching one as an interactive surface. The surface's shared, evolving
//! state rides `code_runs` (see `tests/module_code_block_runners.rs`), not here.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
    Store, User,
};
use tower::ServiceExt;
use uuid::Uuid;

mod support;
use support::wasm_fixtures::{canned_ok_wasm, sha256_hex};

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
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

/// The launcher: a member who clears VIEW_CHANNEL and SEND_MESSAGES through the
/// default `everyone` role. That role carries no module permission, so a
/// launch's module gate (decision 0021) is exercised on its own.
async fn member(s: &Store) -> User {
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    s.create_role("everyone", view_send, true).await.unwrap();
    s.create_user("nia", "Nia").await.unwrap()
}

/// Installs `widget` with a `surf` command and an `app` extension point that
/// launches it, both gated on the `play` permission.
async fn install(s: &Store, enabled: bool) {
    let wasm = canned_ok_wasm("done");
    let sha256 = sha256_hex(&wasm);
    s.install_module(InstallModuleRequest {
        id: "widget",
        name: "Widget",
        version: "0.1.0",
        artifact_sha256: &sha256,
        approved_capabilities: &[],
        runtime_limits: &ModuleRuntimeLimits::default(),
        permissions: &[ModulePermissionSpec {
            key: "play",
            name: "Play the widget",
            description: "launch and play it",
        }],
        extension_points: &[
            ModuleExtensionPointSpec {
                kind: "command",
                name: "surf",
                description: Some("draws a surface"),
                permission: Some("play"),
                command: None,
                language: None,
            },
            ModuleExtensionPointSpec {
                kind: "app",
                name: "Widget",
                description: Some("Launch the widget in chat"),
                permission: Some("play"),
                command: Some("surf"),
                language: None,
            },
        ],
    })
    .await
    .unwrap();
    s.store_module_artifact("widget", &sha256, &wasm)
        .await
        .unwrap();
    if enabled {
        s.set_module_enabled("widget", true).await.unwrap();
    }
}

/// Grants `widget:play` to a fresh role and assigns it to `user`.
async fn grant_play(s: &Store, user: &User) {
    let role = s
        .create_role("players", Permissions::NONE, false)
        .await
        .unwrap();
    s.assign_role(user.id, role).await.unwrap();
    s.grant_module_permission(role, "widget", "play")
        .await
        .unwrap();
}

fn get(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

fn post(uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn no_installed_module_answers_an_empty_app_list() {
    let (s, _guard) = store("slimm-apps-none").await;
    let user = member(&s).await;
    let token = s.open_session(user.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(get("/modules/apps", token.access_token.as_str()))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(json_body(response).await, json!([]));
}

#[tokio::test]
async fn a_disabled_or_unpermitted_module_is_never_offered_as_an_app() {
    let (s, _guard) = store("slimm-apps-hidden").await;
    let user = member(&s).await;
    install(&s, false).await;
    grant_play(&s, &user).await;
    let token = s.open_session(user.id, "phone").await.unwrap();
    let router = app(s.clone());

    // Disabled: never offered.
    let disabled = router
        .clone()
        .oneshot(get("/modules/apps", token.access_token.as_str()))
        .await
        .unwrap();
    assert_eq!(json_body(disabled).await, json!([]));

    // Enabled but the permission stripped: still never offered.
    s.set_module_enabled("widget", true).await.unwrap();
    let (s2, _g2) = store("slimm-apps-noperm").await;
    let stranger = member(&s2).await;
    install(&s2, true).await;
    let stranger_token = s2.open_session(stranger.id, "phone").await.unwrap();
    let no_perm = app(s2)
        .oneshot(get("/modules/apps", stranger_token.access_token.as_str()))
        .await
        .unwrap();
    assert_eq!(json_body(no_perm).await, json!([]));
}

#[tokio::test]
async fn a_permission_holder_is_offered_the_app_with_its_name() {
    let (s, _guard) = store("slimm-apps-offered").await;
    let user = member(&s).await;
    install(&s, true).await;
    grant_play(&s, &user).await;
    let token = s.open_session(user.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(get("/modules/apps", token.access_token.as_str()))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        json_body(response).await,
        json!([{
            "module_id": "widget",
            "command": "surf",
            "name": "Widget",
            "description": "Launch the widget in chat"
        }])
    );
}

#[tokio::test]
async fn launching_an_app_posts_a_message_carrying_the_surface() {
    let (s, _guard) = store("slimm-apps-launch").await;
    let user = member(&s).await;
    install(&s, true).await;
    grant_play(&s, &user).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(post(
            &format!("/channels/{}/messages/apps", channel.id),
            token.access_token.as_str(),
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "check this out",
                "module_id": "widget",
                "command": "surf",
            }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["content"], "check this out");
    assert_eq!(body["app_surface"]["module_id"], "widget");
    assert_eq!(body["app_surface"]["command"], "surf");
    // No run has happened yet: the surface renders from the shared code-run, which the client kicks off on mount.
    assert_eq!(body["code_runs"], json!([]));
}

#[tokio::test]
async fn launching_the_same_id_twice_returns_the_same_message() {
    let (s, _guard) = store("slimm-apps-idempotent").await;
    let user = member(&s).await;
    install(&s, true).await;
    grant_play(&s, &user).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap();
    let router = app(s);
    let id = Uuid::now_v7().to_string();
    let body = json!({ "id": id, "module_id": "widget", "command": "surf" });

    let first = json_body(
        router
            .clone()
            .oneshot(post(
                &format!("/channels/{}/messages/apps", channel.id),
                token.access_token.as_str(),
                body.clone(),
            ))
            .await
            .unwrap(),
    )
    .await;
    let second = json_body(
        router
            .oneshot(post(
                &format!("/channels/{}/messages/apps", channel.id),
                token.access_token.as_str(),
                body,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(first["id"], second["id"]);
    assert_eq!(first["seq"], second["seq"]);
}

/// The module gate is separate from the channel gate: the owner clears
/// VIEW_CHANNEL and SEND_MESSAGES through ADMINISTRATOR, yet a launch is still
/// refused until they hold the app's own module permission.
#[tokio::test]
async fn launching_without_the_module_permission_is_forbidden() {
    let (s, _guard) = store("slimm-apps-no-module-perm").await;
    let user = member(&s).await;
    install(&s, true).await;
    // Deliberately never granted `widget:play`.
    let channel = s.create_channel("general", "text").await.unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(post(
            &format!("/channels/{}/messages/apps", channel.id),
            token.access_token.as_str(),
            json!({ "id": Uuid::now_v7().to_string(), "module_id": "widget", "command": "surf" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// A command with no `app` extension point of its own can never be launched as
/// a surface, even by someone who holds its permission - `app` and `command`
/// are separate kinds, and only the former means "launchable as a surface".
#[tokio::test]
async fn a_command_with_no_app_extension_point_cannot_be_launched() {
    let (s, _guard) = store("slimm-apps-command-only").await;
    let user = member(&s).await;
    let wasm = canned_ok_wasm("done");
    let sha256 = sha256_hex(&wasm);
    s.install_module(InstallModuleRequest {
        id: "widget",
        name: "Widget",
        version: "0.1.0",
        artifact_sha256: &sha256,
        approved_capabilities: &[],
        runtime_limits: &ModuleRuntimeLimits::default(),
        permissions: &[ModulePermissionSpec {
            key: "play",
            name: "Play the widget",
            description: "launch it",
        }],
        extension_points: &[ModuleExtensionPointSpec {
            kind: "command",
            name: "surf",
            description: Some("draws a surface"),
            permission: Some("play"),
            command: None,
            language: None,
        }],
    })
    .await
    .unwrap();
    s.store_module_artifact("widget", &sha256, &wasm)
        .await
        .unwrap();
    s.set_module_enabled("widget", true).await.unwrap();
    grant_play(&s, &user).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(post(
            &format!("/channels/{}/messages/apps", channel.id),
            token.access_token.as_str(),
            json!({ "id": Uuid::now_v7().to_string(), "module_id": "widget", "command": "surf" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// What the launch route accepts is exactly what `/modules/apps` offers: an
/// unknown command, a disabled module and a missing permission all refuse.
#[tokio::test]
async fn a_launch_is_refused_unless_the_app_would_be_offered() {
    let (s, _guard) = store("slimm-apps-launch-gate").await;
    let user = member(&s).await;
    install(&s, true).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap();
    let tok = token.access_token.as_str();
    let router = app(s.clone());
    let launch = |command: &str| {
        post(
            &format!("/channels/{}/messages/apps", channel.id),
            tok,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "",
                "module_id": "widget",
                "command": command,
            }),
        )
    };

    let status =
        |request: Request<Body>| async { router.clone().oneshot(request).await.unwrap().status() };
    assert_eq!(
        status(launch("surf")).await,
        StatusCode::FORBIDDEN,
        "no play permission"
    );
    grant_play(&s, &user).await;
    assert_eq!(
        status(launch("nope")).await,
        StatusCode::FORBIDDEN,
        "no such command"
    );
    assert_eq!(
        status(launch("surf")).await,
        StatusCode::OK,
        "offered, so launchable"
    );
    s.set_module_enabled("widget", false).await.unwrap();
    assert_eq!(
        status(launch("surf")).await,
        StatusCode::FORBIDDEN,
        "disabled"
    );
}
