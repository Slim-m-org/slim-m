// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module that returns a scene with `sweep` animations cannot exceed the
//! ceilings through the shared run route: the stored (and broadcast) scene has
//! the sweeps clamped, and the surplus dropped. See decision 0043.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
    NewMessage, Store,
};
use tower::ServiceExt;

mod support;
use support::wasm_fixtures::{canned_raw_wasm, sha256_hex};

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
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

/// Installs a `run` command whose module always answers with `scene`.
async fn install(s: &Store, scene: &Value) {
    let output = serde_json::to_string(&scene.to_string()).unwrap();
    let wasm = canned_raw_wasm(format!(r#"{{"ok":true,"output":{output}}}"#).as_bytes());
    let sha256 = sha256_hex(&wasm);
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "clock",
            name: "clock",
            version: "0.1.0",
            artifact_sha256: &sha256,
            approved_capabilities: &[],
            runtime_limits: &ModuleRuntimeLimits::default(),
            permissions: &[ModulePermissionSpec {
                key: "play",
                name: "Play",
                description: "play it",
            }],
            extension_points: &[ModuleExtensionPointSpec {
                kind: "command",
                name: "run",
                description: Some("runs it"),
                permission: Some("play"),
                command: None,
                language: None,
            }],
        },
        &wasm,
    )
    .await
    .unwrap();
    s.set_module_enabled("clock", true).await.unwrap();
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

#[tokio::test]
async fn a_shared_scene_is_stored_with_its_sweeps_inside_the_ceilings() {
    let (s, _guard) = new_store("slimm-scene-sweep-limits").await;
    s.create_role(
        "everyone",
        Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
        true,
    )
    .await
    .unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    let user = s.create_user("orin", "Orin").await.unwrap();
    let role = s
        .create_role("clock-players", Permissions::NONE, false)
        .await
        .unwrap();
    s.assign_role(user.id, role).await.unwrap();
    let ops: Vec<Value> = (0..12)
        .map(|i| json!({"op": "rect", "x": i, "sweep": {"dx": 5, "secs": 3600}}))
        .collect();
    install(&s, &json!({"$slim": "scene/1", "ops": ops})).await;
    s.grant_module_permission(role, "clock", "play")
        .await
        .unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap().access_token;
    let message_id = MessageId::generate();
    s.send_message(NewMessage::plain(
        channel.id,
        user.id,
        message_id,
        "```\ntick\n```",
    ))
    .await
    .unwrap();

    let response = app(s.clone())
        .oneshot(post(
            &format!("/messages/{message_id}/blocks/0/run"),
            &token,
            json!({ "module_id": "clock", "command": "run", "input": "" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let stored = s.code_runs_for_messages(&[message_id]).await.unwrap();
    let scene: Value = serde_json::from_str(&stored[0].1[0].output).unwrap();
    let ops = scene["ops"].as_array().unwrap();
    let swept: Vec<&Value> = ops.iter().filter_map(|op| op.get("sweep")).collect();
    assert_eq!(swept.len(), 8, "the four surplus animated ops draw still");
    assert!(swept.iter().all(|sweep| sweep["secs"] == 10.0));
}
