// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /modules/code-block-runners`: the general discovery mechanism a
//! client uses to decide whether to offer "Run" on a fenced code block, per
//! docs/decisions/0021-modules-and-the-dock.md's module-agnostic principle -
//! slim has no notion of "code execution" anywhere in this route, only of an
//! installed, enabled module that declared a `code-block-runner` extension
//! point the caller holds the permission for.
//!
//! `tests/module_commands.rs` covers running a command once discovered; this
//! file is only about which `(module_id, command)` pairs a caller is shown.

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
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
    Store, User,
};
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

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
        voice: VoiceService::disabled(),
        media: Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

async fn deployment(s: &Store) -> User {
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    s.create_role("everyone", view_send, true).await.unwrap();
    s.create_user("nia", "Nia").await.unwrap()
}

/// Installs `code-exec` with both a `run` command and a `code-block-runner`
/// extension point that invokes it, both gated on the `run` permission.
async fn install(s: &Store, enabled: bool) {
    let wasm = canned_ok_wasm("done");
    let sha256 = sha256_hex(&wasm);
    let permissions = vec![ModulePermissionSpec {
        key: "run",
        name: "Execute code blocks",
        description: "run a snippet",
    }];
    let extension_points = vec![
        ModuleExtensionPointSpec {
            kind: "command",
            name: "run",
            description: Some("runs it"),
            permission: Some("run"),
            command: None,
            language: None,
        },
        ModuleExtensionPointSpec {
            kind: "code-block-runner",
            name: "Run in chat",
            description: Some("offers Run on a fenced code block"),
            permission: Some("run"),
            command: Some("run"),
            language: Some("javascript"),
        },
    ];
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "code-exec",
            name: "Code Blocks",
            version: "0.1.0",
            artifact_sha256: &sha256,
            approved_capabilities: &[],
            runtime_limits: &ModuleRuntimeLimits::default(),
            permissions: &permissions,
            extension_points: &extension_points,
        },
        &wasm,
    )
    .await
    .unwrap();
    if enabled {
        s.set_module_enabled("code-exec", true).await.unwrap();
    }
}

/// Grants `code-exec:run` to a fresh role and assigns it to `user`.
async fn grant_run_permission(s: &Store, user: &User) {
    let role = s
        .create_role("coders", Permissions::NONE, false)
        .await
        .unwrap();
    s.assign_role(user.id, role).await.unwrap();
    s.grant_module_permission(role, "code-exec", "run")
        .await
        .unwrap();
}

fn req(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
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
async fn no_installed_module_answers_an_empty_list() {
    let (s, _guard) = store("slimm-runners-none").await;
    let member = deployment(&s).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req(
            "/modules/code-block-runners",
            token.access_token.as_str(),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(json_body(response).await, json!([]));
}

#[tokio::test]
async fn an_installed_but_disabled_module_is_never_offered() {
    let (s, _guard) = store("slimm-runners-disabled").await;
    let member = deployment(&s).await;
    install(&s, false).await;
    grant_run_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req(
            "/modules/code-block-runners",
            token.access_token.as_str(),
        ))
        .await
        .unwrap();
    assert_eq!(json_body(response).await, json!([]));
}

#[tokio::test]
async fn an_enabled_module_is_hidden_from_a_caller_without_the_permission() {
    let (s, _guard) = store("slimm-runners-no-perm").await;
    let member = deployment(&s).await;
    install(&s, true).await;
    // Deliberately never granted.
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req(
            "/modules/code-block-runners",
            token.access_token.as_str(),
        ))
        .await
        .unwrap();
    assert_eq!(json_body(response).await, json!([]));
}

#[tokio::test]
async fn a_permission_holder_is_offered_the_installed_runner() {
    let (s, _guard) = store("slimm-runners-ok").await;
    let member = deployment(&s).await;
    install(&s, true).await;
    grant_run_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req(
            "/modules/code-block-runners",
            token.access_token.as_str(),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        json_body(response).await,
        json!([{ "module_id": "code-exec", "command": "run", "language": "javascript" }])
    );
}

/// A `code-block-runner` with no declared `language` is a wildcard, matching
/// any fenced block on the client side - the discovery response omits the
/// field entirely rather than sending it as `null`, so an older client's
/// deserializer (which already treats the field as optional) sees exactly
/// what it always has.
#[tokio::test]
async fn a_runner_with_no_language_is_offered_as_a_wildcard() {
    let (s, _guard) = store("slimm-runners-wildcard").await;
    let member = deployment(&s).await;
    let wasm = canned_ok_wasm("done");
    let sha256 = sha256_hex(&wasm);
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "code-exec",
            name: "Code Blocks",
            version: "0.1.0",
            artifact_sha256: &sha256,
            approved_capabilities: &[],
            runtime_limits: &ModuleRuntimeLimits::default(),
            permissions: &[ModulePermissionSpec {
                key: "run",
                name: "Execute code blocks",
                description: "run a snippet",
            }],
            extension_points: &[
                ModuleExtensionPointSpec {
                    kind: "command",
                    name: "run",
                    description: Some("runs it"),
                    permission: Some("run"),
                    command: None,
                    language: None,
                },
                ModuleExtensionPointSpec {
                    kind: "code-block-runner",
                    name: "Run in chat",
                    description: Some("offers Run on a fenced code block"),
                    permission: Some("run"),
                    command: Some("run"),
                    language: None,
                },
            ],
        },
        &wasm,
    )
    .await
    .unwrap();
    s.set_module_enabled("code-exec", true).await.unwrap();
    grant_run_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req(
            "/modules/code-block-runners",
            token.access_token.as_str(),
        ))
        .await
        .unwrap();
    assert_eq!(
        json_body(response).await,
        json!([{ "module_id": "code-exec", "command": "run" }])
    );
}

/// A plain `command` extension point with no `code-block-runner` of its own
/// must never be offered as a Run affordance - the two are separate kinds,
/// and only the latter means "show Run on a fenced code block".
#[tokio::test]
async fn a_module_with_only_a_command_extension_point_is_never_offered() {
    let (s, _guard) = store("slimm-runners-command-only").await;
    let member = deployment(&s).await;
    let wasm = canned_ok_wasm("done");
    let sha256 = sha256_hex(&wasm);
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "code-exec",
            name: "Code Blocks",
            version: "0.1.0",
            artifact_sha256: &sha256,
            approved_capabilities: &[],
            runtime_limits: &ModuleRuntimeLimits::default(),
            permissions: &[ModulePermissionSpec {
                key: "run",
                name: "Execute code blocks",
                description: "run a snippet",
            }],
            extension_points: &[ModuleExtensionPointSpec {
                kind: "command",
                name: "run",
                description: Some("runs it"),
                permission: Some("run"),
                command: None,
                language: None,
            }],
        },
        &wasm,
    )
    .await
    .unwrap();
    s.set_module_enabled("code-exec", true).await.unwrap();
    grant_run_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req(
            "/modules/code-block-runners",
            token.access_token.as_str(),
        ))
        .await
        .unwrap();
    assert_eq!(json_body(response).await, json!([]));
}
