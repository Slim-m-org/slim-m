// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /modules/slash-commands`: the discovery mechanism a client uses to
//! decide which `/name` commands to offer in the composer, per
//! docs/decisions/0021-modules-and-the-dock.md's module-agnostic principle -
//! slim has no notion of any particular command, only of an installed,
//! enabled module that declared a `slash-command` extension point the caller
//! holds the permission for.
//!
//! `tests/module_commands.rs` covers running a command once discovered; this
//! file is only about which commands a caller is shown.

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

/// Installs `dice` with a `roll` command and a `slash-command` extension point
/// that invokes it, both gated on the `roll` permission.
async fn install(s: &Store, enabled: bool) {
    let wasm = canned_ok_wasm("done");
    let sha256 = sha256_hex(&wasm);
    let permissions = vec![ModulePermissionSpec {
        key: "roll",
        name: "Roll dice",
        description: "roll dice",
    }];
    let extension_points = vec![
        ModuleExtensionPointSpec {
            kind: "command",
            name: "roll",
            description: Some("rolls dice"),
            permission: Some("roll"),
            command: None,
            language: None,
        },
        ModuleExtensionPointSpec {
            kind: "slash-command",
            name: "roll",
            description: Some("Roll dice like 2d20+3"),
            permission: Some("roll"),
            command: Some("roll"),
            language: None,
        },
    ];
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "dice",
            name: "Dice",
            version: "0.2.0",
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
        s.set_module_enabled("dice", true).await.unwrap();
    }
}

/// Grants `dice:roll` to a fresh role and assigns it to `user`.
async fn grant_roll_permission(s: &Store, user: &User) {
    let role = s
        .create_role("players", Permissions::NONE, false)
        .await
        .unwrap();
    s.assign_role(user.id, role).await.unwrap();
    s.grant_module_permission(role, "dice", "roll")
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
    let (s, _guard) = store("slimm-slash-none").await;
    let member = deployment(&s).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req("/modules/slash-commands", token.access_token.as_str()))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(json_body(response).await, json!([]));
}

#[tokio::test]
async fn an_installed_but_disabled_module_is_never_offered() {
    let (s, _guard) = store("slimm-slash-disabled").await;
    let member = deployment(&s).await;
    install(&s, false).await;
    grant_roll_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req("/modules/slash-commands", token.access_token.as_str()))
        .await
        .unwrap();
    assert_eq!(json_body(response).await, json!([]));
}

#[tokio::test]
async fn an_enabled_module_is_hidden_from_a_caller_without_the_permission() {
    let (s, _guard) = store("slimm-slash-no-perm").await;
    let member = deployment(&s).await;
    install(&s, true).await;
    // Deliberately never granted.
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req("/modules/slash-commands", token.access_token.as_str()))
        .await
        .unwrap();
    assert_eq!(json_body(response).await, json!([]));
}

#[tokio::test]
async fn a_permission_holder_is_offered_the_slash_command_with_its_name() {
    let (s, _guard) = store("slimm-slash-ok").await;
    let member = deployment(&s).await;
    install(&s, true).await;
    grant_roll_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req("/modules/slash-commands", token.access_token.as_str()))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        json_body(response).await,
        json!([{
            "module_id": "dice",
            "command": "roll",
            "name": "roll",
            "description": "Roll dice like 2d20+3"
        }])
    );
}

/// A plain `command` extension point with no `slash-command` of its own must
/// never appear in the composer - the two are separate kinds, and only the
/// latter means "offer this as `/name`".
#[tokio::test]
async fn a_module_with_only_a_command_extension_point_is_never_offered() {
    let (s, _guard) = store("slimm-slash-command-only").await;
    let member = deployment(&s).await;
    let wasm = canned_ok_wasm("done");
    let sha256 = sha256_hex(&wasm);
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "dice",
            name: "Dice",
            version: "0.2.0",
            artifact_sha256: &sha256,
            approved_capabilities: &[],
            runtime_limits: &ModuleRuntimeLimits::default(),
            permissions: &[ModulePermissionSpec {
                key: "roll",
                name: "Roll dice",
                description: "roll dice",
            }],
            extension_points: &[ModuleExtensionPointSpec {
                kind: "command",
                name: "roll",
                description: Some("rolls dice"),
                permission: Some("roll"),
                command: None,
                language: None,
            }],
        },
        &wasm,
    )
    .await
    .unwrap();
    s.set_module_enabled("dice", true).await.unwrap();
    grant_roll_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req("/modules/slash-commands", token.access_token.as_str()))
        .await
        .unwrap();
    assert_eq!(json_body(response).await, json!([]));
}
