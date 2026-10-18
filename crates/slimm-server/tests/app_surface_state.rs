// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A shared app surface keeps its scene state on the server: a press carrying
//! a different `state` is run with the one the server stored, so nobody can
//! forge a board by sending their own.

use axum::Router;
use axum::body::Body;
use axum::http::Request;
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
    Store,
};
use tower::ServiceExt;
use uuid::Uuid;

mod support;
use support::wasm_fixtures::{canned_raw_wasm, echo_request_wasm, sha256_hex};

const SCENE: &[u8] =
    br#"{"ok":true,"output":"{\"$slim\":\"scene/1\",\"ops\":[],\"state\":\"real\"}"}"#;

async fn install(s: &Store, wasm: Vec<u8>) {
    let sha256 = sha256_hex(&wasm);
    let points = [
        ModuleExtensionPointSpec {
            kind: "command",
            name: "run",
            description: None,
            permission: Some("play"),
            command: None,
            language: None,
        },
        ModuleExtensionPointSpec {
            kind: "app",
            name: "Board",
            description: None,
            permission: Some("play"),
            command: Some("run"),
            language: None,
        },
    ];
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "board",
            name: "Board",
            version: "0.1.0",
            artifact_sha256: &sha256,
            approved_capabilities: &[],
            runtime_limits: &ModuleRuntimeLimits::default(),
            permissions: &[ModulePermissionSpec {
                key: "play",
                name: "Play",
                description: "play",
            }],
            extension_points: &points,
        },
        &wasm,
    )
    .await
    .unwrap();
    s.set_module_enabled("board", true).await.unwrap();
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
async fn a_forged_state_is_replaced_by_the_one_the_server_stored() {
    let (path, _guard) = support::TestDbGuard::new("slimm-surface-state");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let s = Store::new(db::connect(&config).await.unwrap());
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
        .create_role("players", Permissions::NONE, false)
        .await
        .unwrap();
    s.assign_role(user.id, role).await.unwrap();
    install(&s, canned_raw_wasm(SCENE)).await;
    s.grant_module_permission(role, "board", "play")
        .await
        .unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap().access_token;
    let router: Router = http::router(AppState {
        store: s.clone(),
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
    });

    let launch = json_body(
        router
            .clone()
            .oneshot(post(
                &format!("/channels/{}/messages/apps", channel.id),
                &token,
                json!({"id": Uuid::now_v7().to_string(), "module_id": "board", "command": "run"}),
            ))
            .await
            .unwrap(),
    )
    .await;
    let message = MessageId(launch["id"].as_str().unwrap().parse().unwrap());
    let run = |input: &str| {
        post(
            &format!("/messages/{message}/blocks/0/run"),
            &token,
            json!({"module_id": "board", "command": "run", "input": input}),
        )
    };
    assert_eq!(router.clone().oneshot(run("")).await.unwrap().status(), 200);

    // From here the module echoes what it was asked, so the test sees the state it was handed.
    install(&s, echo_request_wasm()).await;
    let seen = json_body(
        router
            .oneshot(run(r#"{"action":"tap","state":"forged"}"#))
            .await
            .unwrap(),
    )
    .await;
    let output = seen["output"].as_str().unwrap();
    assert!(
        output.contains("real"),
        "the stored state was not used: {output}"
    );
    assert!(
        !output.contains("forged"),
        "the client's state reached the module: {output}"
    );
}
