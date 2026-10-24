// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A deployment with one member, plus helpers to install a wasm fixture as an
//! approved module and run it through the real command route.

use axum::Router;
use axum::body::Body;
use axum::http::Request;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::{ChannelId, MessageId, RoleId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
    Store, User,
};
use tower::ServiceExt;

use super::wasm_fixtures::sha256_hex;

pub struct World {
    pub state: AppState,
    pub store: Store,
    pub router: Router,
    pub hub: Hub,
    pub everyone: RoleId,
    pub user: User,
    pub token: String,
    pub db_path: String,
    pub modules_dir: std::path::PathBuf,
    _guard: super::TestDbGuard,
    _modules_guard: super::TestDirGuard,
}

pub async fn world(name: &str) -> World {
    let (path, guard) = super::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path.clone(),
        hash_concurrency: 2,
        ..Config::default()
    };
    let (modules_dir, modules_guard) = super::TestDirGuard::new("slimm-modworld-data");
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"))
        .with_modules_dir(modules_dir.clone());
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    let everyone = store
        .create_role("everyone", view_send, true)
        .await
        .unwrap();
    let user = store.create_user("nia", "Nia").await.unwrap();
    let token = store
        .open_session(user.id, "phone")
        .await
        .unwrap()
        .access_token;
    let hub = Hub::new();
    let state = super::app::builder(store.clone()).hub(hub.clone()).build();
    let router = http::router(state.clone());
    World {
        state,
        store,
        router,
        hub,
        everyone,
        user,
        token,
        db_path: path,
        modules_dir,
        _guard: guard,
        _modules_guard: modules_guard,
    }
}

/// What an install looks like once an admin has approved `approved_host`.
pub struct Install<'a> {
    pub id: &'a str,
    pub wasm: Vec<u8>,
    pub declared: &'a [&'a str],
    pub approved_host: &'a [&'a str],
}

impl World {
    /// Installs and enables `module`, stores its artifact, records the admin's
    /// approval, and lets `nia` run its `run` command.
    pub async fn install(&self, module: Install<'_>) {
        let Install {
            id,
            wasm,
            declared,
            approved_host,
        } = module;
        let sha256 = sha256_hex(&wasm);
        let declared: Vec<String> = declared
            .iter()
            .map(std::string::ToString::to_string)
            .collect();
        let permissions = [ModulePermissionSpec {
            key: "run",
            name: "Run",
            description: "run it",
        }];
        let points = [ModuleExtensionPointSpec {
            kind: "command",
            name: "run",
            description: None,
            permission: Some("run"),
            command: None,
            language: None,
        }];
        let s = &self.store;
        s.install_module_with_artifact(
            InstallModuleRequest {
                id,
                name: "Scorekeeper",
                version: "0.1.0",
                artifact_sha256: &sha256,
                approved_capabilities: &declared,
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &permissions,
                extension_points: &points,
            },
            &wasm,
        )
        .await
        .unwrap();
        let approved: Vec<String> = approved_host
            .iter()
            .map(std::string::ToString::to_string)
            .collect();
        s.set_module_host_capabilities(id, &approved).await.unwrap();
        s.set_module_enabled(id, true).await.unwrap();
        let role = s
            .create_role(&format!("runs-{id}"), Permissions::NONE, false)
            .await
            .unwrap();
        s.assign_role(self.user.id, role).await.unwrap();
        s.grant_module_permission(role, id, "run").await.unwrap();
    }

    /// Runs `module`'s command as `nia`, from `channel` when given; returns
    /// the route's JSON answer.
    pub async fn run_in(&self, module: &str, channel: Option<ChannelId>) -> Value {
        let mut body = json!({ "input": "go" });
        if let Some(channel) = channel {
            body["channel_id"] = json!(channel.to_string());
        }
        let request = Request::builder()
            .method("POST")
            .uri(format!("/modules/{module}/commands/run"))
            .header("authorization", format!("Bearer {}", self.token))
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        self.send(request).await
    }

    /// The channel's messages as the list route answers them, newest first.
    pub async fn list_messages_json(&self, channel: ChannelId) -> Vec<Value> {
        let request = Request::builder()
            .uri(format!("/channels/{channel}/messages"))
            .header("authorization", format!("Bearer {}", self.token))
            .body(Body::empty())
            .unwrap();
        self.send(request)
            .await
            .as_array()
            .cloned()
            .expect("a message list")
    }

    pub async fn send(&self, request: Request<Body>) -> Value {
        let response = self.router.clone().oneshot(request).await.unwrap();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    /// The text a module reported, whether it succeeded or was refused, for a
    /// run that names no channel.
    pub async fn answer(&self, module: &str) -> String {
        self.answer_in(module, None).await
    }

    /// As [`World::answer`], for a command invoked from `channel`.
    pub async fn answer_in(&self, module: &str, channel: Option<ChannelId>) -> String {
        let body = self.run_in(module, channel).await;
        body["output"]
            .as_str()
            .or_else(|| body["error"].as_str())
            .unwrap_or_else(|| panic!("no output or error in {body}"))
            .to_owned()
    }
}

pub fn kv_request(op: &str, key: &str, value: Option<&str>) -> String {
    let mut request = json!({ "capability": "kv.store", "op": op, "key": key });
    if let Some(value) = value {
        request["value"] = json!(value);
    }
    request.to_string()
}

pub fn post_request(channel: &str, content: &str) -> String {
    json!({ "capability": "message.post", "channel_id": channel, "content": content }).to_string()
}

pub fn message_id_in(answer: &str) -> MessageId {
    let start = answer.find("'message_id':'").expect("a message id") + "'message_id':'".len();
    let raw = &answer[start..start + 36];
    MessageId(raw.parse().expect("a uuid"))
}
