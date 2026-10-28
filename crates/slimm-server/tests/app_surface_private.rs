// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A scene marked `private` on an app surface answers only the person who pressed: it is not
//! stored as the surface's frame and not broadcast. A shared scene still is, and a code block
//! run ignores the flag. See docs/decisions/0099-private-scenes.md.

use axum::Router;
use axum::body::Body;
use axum::http::Request;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http;
use slimm_server::hub::Event;
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
    Store,
};
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::json_body;
use support::wasm_fixtures::{canned_raw_wasm, sha256_hex};

const SHARED: &[u8] =
    br#"{"ok":true,"output":"{\"$slim\":\"scene/1\",\"ops\":[],\"state\":\"shared\"}"}"#;
const PRIVATE: &[u8] =
    br#"{"ok":true,"output":"{\"$slim\":\"scene/1\",\"private\":true,\"ops\":[],\"state\":\"mine\"}"}"#;
const PRIVATE_FALSE: &[u8] =
    br#"{"ok":true,"output":"{\"$slim\":\"scene/1\",\"private\":false,\"ops\":[],\"state\":\"s\"}"}"#;
const NOT_A_SCENE: &[u8] = br#"{"ok":true,"output":"{\"private\":true,\"state\":\"x\"}"}"#;

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

struct World {
    store: Store,
    state: slimm_server::http::AppState,
    router: Router,
    token: String,
    message: MessageId,
}

impl World {
    async fn run(&self, input: &str) -> Value {
        json_body(
            self.router
                .clone()
                .oneshot(post(
                    &format!("/messages/{}/blocks/0/run", self.message),
                    &self.token,
                    json!({"module_id": "board", "command": "run", "input": input}),
                ))
                .await
                .unwrap(),
        )
        .await
    }

    async fn stored(&self) -> Vec<String> {
        let runs = self
            .store
            .code_runs_for_messages(&[self.message])
            .await
            .unwrap();
        runs.into_iter()
            .flat_map(|(_, r)| r)
            .map(|r| r.output)
            .collect()
    }
}

async fn world(prefix: &str, first: &[u8]) -> (World, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(prefix);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let user = store.create_user("orin", "Orin").await.unwrap();
    let role = store
        .create_role("players", Permissions::NONE, false)
        .await
        .unwrap();
    store.assign_role(user.id, role).await.unwrap();
    install(&store, canned_raw_wasm(first)).await;
    store
        .grant_module_permission(role, "board", "play")
        .await
        .unwrap();
    let token = store
        .open_session(user.id, "phone")
        .await
        .unwrap()
        .access_token;
    let state = support::app::state(store.clone());
    let router: Router = http::router(state.clone());
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
    (
        World {
            store,
            state,
            router,
            token,
            message,
        },
        guard,
    )
}

#[tokio::test]
async fn a_private_scene_is_returned_to_the_caller_and_never_stored_or_broadcast() {
    let (w, _guard) = world("slimm-private-scene", SHARED).await;
    let shared = w.run("").await;
    assert_eq!(shared["ok"], true);
    assert_eq!(w.stored().await.len(), 1, "a shared frame is stored");

    install(&w.store, canned_raw_wasm(PRIVATE)).await;
    let mut events = w.state.hub.subscribe();
    let mine = w.run(r#"{"action":"guess:crane"}"#).await;
    assert_eq!(mine["ok"], true);
    assert!(
        mine["output"]
            .as_str()
            .unwrap()
            .contains("\"state\":\"mine\""),
        "{mine}"
    );

    let kept = w.stored().await;
    assert_eq!(kept.len(), 1);
    assert!(
        kept[0].contains("\"state\":\"shared\""),
        "the shared frame was replaced: {kept:?}"
    );
    while let Ok(event) = events.try_recv() {
        assert!(
            !matches!(event, Event::CodeRunChanged { .. }),
            "a private scene was broadcast"
        );
    }
}

#[tokio::test]
async fn a_shared_scene_is_still_stored_and_broadcast() {
    let (w, _guard) = world("slimm-private-shared", SHARED).await;
    let mut events = w.state.hub.subscribe();
    w.run("").await;
    let mut broadcast = false;
    while let Ok(event) = events.try_recv() {
        broadcast |= matches!(event, Event::CodeRunChanged { .. });
    }
    assert!(broadcast && w.stored().await.len() == 1);
}

#[tokio::test]
async fn private_false_and_a_payload_that_is_not_a_scene_stay_shared() {
    for (name, wasm) in [("false", PRIVATE_FALSE), ("noscene", NOT_A_SCENE)] {
        let (w, _guard) = world(&format!("slimm-private-{name}"), wasm).await;
        w.run("").await;
        assert_eq!(
            w.stored().await.len(),
            1,
            "{name} must be stored like any frame"
        );
    }
}
