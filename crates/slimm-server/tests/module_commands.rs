// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /modules/{moduleId}/commands/{command}`: gating (not installed, not
//! enabled, no such command, missing permission) and the wasm sandbox itself
//! answering cleanly, including when it hits a resource limit. See
//! docs/decisions/0021-modules-and-the-dock.md's Phase 3.
//!
//! `tests/dock.rs` and `crates/slimm-server/src/module_runtime/tests.rs`
//! already cover the artifact fetch/verify path and the host's own ABI
//! mechanics (import refusal, fuel, memory) in isolation; this file is about
//! the route that ties installed-module state, the permission grant, and the
//! host together.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
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
use support::wasm_fixtures::{canned_ok_wasm, echo_request_wasm, fuel_burner_wasm, sha256_hex};

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

/// Installs `code-exec` with one `run` command requiring the `run`
/// permission, and stores `wasm` as its verified artifact. `fuel` lets the
/// fuel-exhaustion test configure a tight budget.
async fn install(s: &Store, wasm: Vec<u8>, enabled: bool, fuel: Option<u64>) {
    let sha256 = sha256_hex(&wasm);
    let permissions = vec![ModulePermissionSpec {
        key: "run",
        name: "Execute code blocks",
        description: "run a snippet",
    }];
    let extension_points = vec![ModuleExtensionPointSpec {
        kind: "command",
        name: "run",
        description: Some("runs it"),
        permission: Some("run"),
        command: None,
        language: None,
    }];
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "code-exec",
            name: "Code Blocks",
            version: "0.1.0",
            artifact_sha256: &sha256,
            approved_capabilities: &[],
            runtime_limits: &ModuleRuntimeLimits {
                fuel,
                ..ModuleRuntimeLimits::default()
            },
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

fn req_json(method: &str, uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method(method)
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
async fn a_module_that_is_not_installed_404s() {
    let (s, _guard) = store("slimm-module-cmd-not-installed").await;
    let member = deployment(&s).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req_json(
            "POST",
            "/modules/code-exec/commands/run",
            token.access_token.as_str(),
            json!({ "input": "hi" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_disabled_module_409s() {
    let (s, _guard) = store("slimm-module-cmd-disabled").await;
    let member = deployment(&s).await;
    install(&s, canned_ok_wasm("done"), false, None).await;
    grant_run_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req_json(
            "POST",
            "/modules/code-exec/commands/run",
            token.access_token.as_str(),
            json!({ "input": "hi" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn an_unknown_command_404s() {
    let (s, _guard) = store("slimm-module-cmd-unknown-command").await;
    let member = deployment(&s).await;
    install(&s, canned_ok_wasm("done"), true, None).await;
    grant_run_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req_json(
            "POST",
            "/modules/code-exec/commands/does-not-exist",
            token.access_token.as_str(),
            json!({ "input": "hi" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_caller_without_the_permission_is_forbidden() {
    let (s, _guard) = store("slimm-module-cmd-forbidden").await;
    let member = deployment(&s).await;
    install(&s, canned_ok_wasm("done"), true, None).await;
    // Deliberately never granted.
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req_json(
            "POST",
            "/modules/code-exec/commands/run",
            token.access_token.as_str(),
            json!({ "input": "hi" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_permission_holder_gets_the_modules_own_output() {
    let (s, _guard) = store("slimm-module-cmd-success").await;
    let member = deployment(&s).await;
    install(&s, canned_ok_wasm("done"), true, None).await;
    grant_run_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(req_json(
            "POST",
            "/modules/code-exec/commands/run",
            token.access_token.as_str(),
            json!({ "input": "hi" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["ok"], json!(true));
    assert_eq!(body["output"], json!("done"));
}

/// The core promise of the sandbox: a module that never returns still
/// answers promptly with a clean `ok: false`, never a 500 and never a hang.
#[tokio::test]
async fn a_fuel_exhausting_module_answers_cleanly_instead_of_hanging() {
    let (s, _guard) = store("slimm-module-cmd-fuel").await;
    let member = deployment(&s).await;
    install(&s, fuel_burner_wasm(), true, Some(10_000)).await;
    grant_run_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let started = std::time::Instant::now();
    let response = router
        .oneshot(req_json(
            "POST",
            "/modules/code-exec/commands/run",
            token.access_token.as_str(),
            json!({ "input": "hi" }),
        ))
        .await
        .unwrap();
    assert!(started.elapsed() < std::time::Duration::from_secs(5));
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["ok"], json!(false));
    assert!(body["error"].as_str().unwrap().contains("limit"));
}

/// The request the wasm sees carries `command`, `input` and an opaque
/// `caller.id`, and nothing else about the caller.
///
/// Opaque has to survive somebody who knows the recipe. The id was a bare
/// sha256 of the module id and the user id, both of which any member can
/// read, so hashing the member list gave back the person behind every id.
#[tokio::test]
async fn the_wasm_receives_an_opaque_caller_id_and_nothing_else() {
    let (s, _guard) = store("slimm-module-cmd-caller").await;
    let member = deployment(&s).await;
    install(&s, echo_request_wasm(), true, None).await;
    grant_run_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let mut answers = Vec::new();
    for _ in 0..2 {
        let response = router
            .clone()
            .oneshot(req_json(
                "POST",
                "/modules/code-exec/commands/run",
                token.access_token.as_str(),
                json!({ "input": "hi" }),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        answers.push(
            json_body(response).await["output"]
                .as_str()
                .unwrap()
                .to_owned(),
        );
    }
    let echoed = &answers[0];
    let id_of = |answer: &str| {
        answer
            .split_once("'entropy'")
            .map(|(head, _)| head.to_owned())
    };
    assert_eq!(
        id_of(echoed),
        id_of(&answers[1]),
        "the id is stable for one person"
    );

    let (id, _entropy) = echoed
        .strip_prefix("{'command':'run','input':'hi','caller':{'id':'")
        .and_then(|rest| rest.strip_suffix("'}"))
        .and_then(|rest| rest.split_once("'},'entropy':'"))
        .unwrap_or_else(|| panic!("the request carries more than it should: {echoed}"));
    assert_eq!(id.len(), 64);
    assert!(id.chars().all(|c| c.is_ascii_hexdigit()));

    let mut public = Sha256::new();
    public.update(format!("slim-module-caller-v1\0code-exec\0{}", member.id));
    assert_ne!(
        id,
        slimm_server::media::to_hex(&public.finalize()),
        "the id can be recomputed from the module id and a user id anybody can list"
    );
    assert!(!echoed.contains(&member.id.to_string()));
    assert!(!echoed.contains("Nia"));
}

/// A module has no clock and no random source, so a command whose answer is
/// meant to vary (a die roll) can only vary with something the host hands it.
/// Every run gets a fresh value, the same for nobody and unrelated to the caller.
#[tokio::test]
async fn every_run_carries_a_fresh_entropy_value() {
    let (s, _guard) = store("slimm-module-cmd-entropy").await;
    let member = deployment(&s).await;
    install(&s, echo_request_wasm(), true, None).await;
    grant_run_permission(&s, &member).await;
    let token = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let mut seen = std::collections::HashSet::new();
    for _ in 0..8 {
        let response = router
            .clone()
            .oneshot(req_json(
                "POST",
                "/modules/code-exec/commands/run",
                token.access_token.as_str(),
                json!({ "input": "hi" }),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let echoed = json_body(response).await["output"]
            .as_str()
            .unwrap()
            .to_owned();
        let entropy = echoed
            .split_once("'entropy':'")
            .and_then(|(_, rest)| rest.strip_suffix("'}"))
            .unwrap_or_else(|| panic!("the request carries no entropy: {echoed}"));
        assert_eq!(entropy.len(), 32);
        assert!(entropy.chars().all(|c| c.is_ascii_hexdigit()));
        seen.insert(entropy.to_owned());
    }
    assert_eq!(seen.len(), 8, "two runs shared an entropy value: {seen:?}");
}
