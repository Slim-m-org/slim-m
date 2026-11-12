// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A shared scene that asks for `refresh_ms` is redrawn by the host with
//! nobody pressing anything, and stops when the module stops asking.

use axum::Router;
use axum::body::Body;
use axum::http::Request;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState, run_scene_refreshes};
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
    Store,
};
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use support::app::json_body;
use support::wasm_fixtures::{canned_raw_wasm, echo_request_wasm, sha256_hex};

fn now_ms() -> i64 {
    let since = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap();
    i64::try_from(since.as_millis()).unwrap()
}

const LIVE: &[u8] = br#"{"ok":true,"output":"{\"$slim\":\"scene/1\",\"ops\":[],\"state\":\"t1\",\"refresh_ms\":3000}"}"#;
const DONE: &[u8] =
    br#"{"ok":true,"output":"{\"$slim\":\"scene/1\",\"ops\":[],\"state\":\"over\"}"}"#;

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
            name: "Timer",
            description: None,
            permission: Some("play"),
            command: Some("run"),
            language: None,
        },
    ];
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "timer",
            name: "Timer",
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
    s.set_module_enabled("timer", true).await.unwrap();
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

struct Rig {
    store: Store,
    state: AppState,
    router: Router,
    message: MessageId,
    token: String,
    _guard: support::TestDbGuard,
}

async fn rig(name: &str) -> Rig {
    let (path, guard) = support::TestDbGuard::new(name);
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
    install(&s, canned_raw_wasm(LIVE)).await;
    s.grant_module_permission(role, "timer", "play")
        .await
        .unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap().access_token;
    let state = support::app::state(s.clone());
    let router: Router = http::router(state.clone());
    let launch = json_body(
        router
            .clone()
            .oneshot(post(
                &format!("/channels/{}/messages/apps", channel.id),
                &token,
                json!({"id": Uuid::now_v7().to_string(), "module_id": "timer", "command": "run"}),
            ))
            .await
            .unwrap(),
    )
    .await;
    let message = MessageId(launch["id"].as_str().unwrap().parse().unwrap());
    Rig {
        store: s,
        state,
        router,
        message,
        token,
        _guard: guard,
    }
}

impl Rig {
    async fn press(&self) {
        let request = post(
            &format!("/messages/{}/blocks/0/run", self.message),
            &self.token,
            json!({"module_id": "timer", "command": "run", "input": ""}),
        );
        assert_eq!(
            self.router.clone().oneshot(request).await.unwrap().status(),
            200
        );
    }

    async fn stored_state(&self) -> String {
        let runs = self
            .store
            .code_runs_for_messages(&[self.message])
            .await
            .unwrap();
        let scene: Value = serde_json::from_str(&runs[0].1[0].output).unwrap();
        scene["state"].as_str().unwrap().to_owned()
    }

    async fn pending(&self) -> usize {
        self.store
            .due_scene_refreshes(i64::MAX, 10)
            .await
            .unwrap()
            .len()
    }
}

#[tokio::test]
async fn a_scene_that_asks_is_redrawn_by_the_host_until_it_stops_asking() {
    let r = rig("slimm-scene-refresh").await;
    r.press().await;
    assert_eq!(r.pending().await, 1, "the press queued a redraw");
    let now = now_ms();
    assert_eq!(
        run_scene_refreshes(&r.state, now).await.unwrap(),
        0,
        "not due yet"
    );

    // From here the module ends the timer, and the next redraw is its last.
    install(&r.store, canned_raw_wasm(DONE)).await;
    assert_eq!(run_scene_refreshes(&r.state, now + 4_000).await.unwrap(), 0);
    assert_eq!(
        r.stored_state().await,
        "over",
        "the host stored the redrawn frame"
    );
    assert_eq!(
        r.pending().await,
        0,
        "a frame that does not ask again ends the chain"
    );
}

#[tokio::test]
async fn a_chain_nobody_renewed_ends_after_its_window() {
    let r = rig("slimm-scene-refresh-window").await;
    r.press().await;
    let now = now_ms();
    assert_eq!(run_scene_refreshes(&r.state, now + 4_000).await.unwrap(), 1);
    let far = now + 31 * 60_000;
    assert_eq!(run_scene_refreshes(&r.state, far).await.unwrap(), 0);
    assert_eq!(r.pending().await, 0);
}

#[tokio::test]
async fn the_redraw_is_asked_with_the_refresh_action_and_the_held_state() {
    let r = rig("slimm-scene-refresh-input").await;
    r.press().await;
    install(&r.store, echo_request_wasm()).await;
    run_scene_refreshes(&r.state, now_ms() + 4_000)
        .await
        .unwrap();
    let runs = r.store.code_runs_for_messages(&[r.message]).await.unwrap();
    let echoed = &runs[0].1[0].output;
    assert!(
        echoed.contains("refresh") && echoed.contains("t1"),
        "{echoed}"
    );
}
