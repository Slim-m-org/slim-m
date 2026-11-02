// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A launched app surface backed by a swappable "board" module, for tests of
//! how the host stores, serializes and replays presses on it.

use axum::Router;
use axum::body::Body;
use axum::http::Request;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http;
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
    Store,
};
use tower::ServiceExt;
use uuid::Uuid;

use super::TestDbGuard;
use super::app::json_body;
use super::wasm_fixtures::sha256_hex;

pub struct BoardWorld {
    pub store: Store,
    pub router: Router,
    pub message: MessageId,
    token: String,
    _guard: TestDbGuard,
}

/// Installs (or reinstalls) the `board` module with `wasm` as its code.
pub async fn install_board(store: &Store, wasm: Vec<u8>) {
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
    let request = InstallModuleRequest {
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
    };
    store
        .install_module_with_artifact(request, &wasm)
        .await
        .unwrap();
    store.set_module_enabled("board", true).await.unwrap();
}

impl BoardWorld {
    /// A surface message for `board` running `wasm`, not yet pressed.
    pub async fn new(prefix: &str, wasm: Vec<u8>) -> Self {
        let (path, guard) = TestDbGuard::new(prefix);
        let config = Config {
            port: 0,
            database_path: path,
            hash_concurrency: 2,
            ..Config::default()
        };
        let store = Store::new(db::connect(&config).await.unwrap());
        let everyone = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
        store.create_role("everyone", everyone, true).await.unwrap();
        let channel = store.create_channel("general", "text").await.unwrap();
        let user = store.create_user("orin", "Orin").await.unwrap();
        let role = store
            .create_role("players", Permissions::NONE, false)
            .await
            .unwrap();
        store.assign_role(user.id, role).await.unwrap();
        install_board(&store, wasm).await;
        store
            .grant_module_permission(role, "board", "play")
            .await
            .unwrap();
        let token = store
            .open_session(user.id, "phone")
            .await
            .unwrap()
            .access_token;
        let router = http::router(super::app::state(store.clone()));
        let launch =
            json!({"id": Uuid::now_v7().to_string(), "module_id": "board", "command": "run"});
        let request = post(
            &format!("/channels/{}/messages/apps", channel.id),
            &token,
            launch,
        );
        let launched = json_body(router.clone().oneshot(request).await.unwrap()).await;
        let message = MessageId(launched["id"].as_str().unwrap().parse().unwrap());
        Self {
            store,
            router,
            message,
            token,
            _guard: guard,
        }
    }

    /// Presses the surface with `input`, answering the status and body.
    pub async fn press(&self, input: &str) -> (u16, Value) {
        let body = json!({"module_id": "board", "command": "run", "input": input});
        let uri = format!("/messages/{}/blocks/0/run", self.message);
        let response = self
            .router
            .clone()
            .oneshot(post(&uri, &self.token, body))
            .await
            .unwrap();
        (response.status().as_u16(), json_body(response).await)
    }

    /// The scene `state` of the frame the surface currently shares.
    pub async fn shared_state(&self) -> String {
        let (_, runs) = self
            .store
            .code_runs_for_messages(&[self.message])
            .await
            .unwrap()
            .remove(0);
        assert!(
            runs[0].ok,
            "the shared frame is a failure: {}",
            runs[0].output
        );
        let scene: Value = serde_json::from_str(&runs[0].output).unwrap();
        scene["state"].as_str().unwrap().to_owned()
    }

    /// The last stored run's `(ok, output)`, whatever it was.
    pub async fn shared_run(&self) -> (bool, String) {
        let runs = self
            .store
            .code_runs_for_messages(&[self.message])
            .await
            .unwrap()
            .remove(0)
            .1;
        (runs[0].ok, runs[0].output.clone())
    }
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
