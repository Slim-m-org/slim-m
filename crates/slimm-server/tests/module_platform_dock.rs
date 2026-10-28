// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The module-platform manifest through the real Dock routes (decision 0091):
//! what an install records and shows, and what a new build must be asked again.

use std::sync::{Arc, Mutex};

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::get;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::dock::Dock;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

use support::app::json_body;
use support::wasm_fixtures::sha256_hex;

const NEW_CAPS: [&str; 3] = ["events", "data.store", "log.read"];

fn artifact_for(version: &str) -> Vec<u8> {
    format!("build {version}").into_bytes()
}

fn manifest(version: &str, extra: &Value) -> Value {
    let sha = sha256_hex(&artifact_for(version));
    let mut m = json!({
        "schema": 1, "id": "xp", "name": "XP", "version": version, "summary": "levels",
        "artifact": {"kind": "wasm", "path": format!("modules/xp/{version}/module.wasm"), "sha256": sha},
        "runtime": {"backend": "wasm"},
        "permissions": [{"key": "run", "name": "Run", "description": "run it"}],
        "capabilities": ["events", "data.store", "log.read"],
        "extension_points": [{"kind": "command", "name": "run", "permission": "run"}],
    });
    for (k, v) in extra.as_object().unwrap() {
        m[k] = v.clone();
    }
    m
}

/// Serves whatever manifest the test currently holds, plus every build's bytes.
async fn registry(current: Arc<Mutex<Value>>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}/", listener.local_addr().unwrap());
    let index = || async {
        axum::Json(json!({"schema": 1, "modules": [
            {"id": "xp", "name": "XP", "version": "1.0.0", "summary": "levels"}]}))
    };
    let router =
        Router::new()
            .route("/index.json", get(index))
            .route(
                "/modules/xp/manifest.json",
                get(move || {
                    let current = current.clone();
                    async move { axum::Json(current.lock().unwrap().clone()) }
                }),
            )
            .route(
                "/modules/xp/{version}/module.wasm",
                get(
                    |axum::extract::Path(v): axum::extract::Path<String>| async move {
                        artifact_for(&v)
                    },
                ),
            );
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    base
}

struct Setup {
    router: Router,
    token: String,
    current: Arc<Mutex<Value>>,
    _guard: support::TestDbGuard,
}

async fn setup(name: &str, first: Value) -> Setup {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = store.create_user("root", "Root").await.unwrap();
    store.assign_role(admin.id, role).await.unwrap();
    let token = store
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let current = Arc::new(Mutex::new(first));
    let dock = Dock::for_test(&registry(current.clone()).await);
    let router = support::app::builder(store).dock(dock).router();
    Setup {
        router,
        token,
        current,
        _guard: guard,
    }
}

impl Setup {
    async fn send(&self, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
        let request = Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("Bearer {}", self.token))
            .header("content-type", "application/json")
            .body(Body::from(body.map(|b| b.to_string()).unwrap_or_default()))
            .unwrap();
        let response = self.router.clone().oneshot(request).await.unwrap();
        (response.status(), json_body(response).await)
    }

    async fn install(&self, version: &str, approve: Option<&[&str]>) -> Value {
        let mut body = json!({ "version": version });
        if let Some(list) = approve {
            body["approved_host_capabilities"] = json!(list);
        }
        let (status, installed) = self
            .send("POST", "/space/dock/modules/xp/install", Some(body))
            .await;
        assert_eq!(status, StatusCode::OK, "{installed}");
        installed
    }
}

fn platform_manifest() -> Value {
    json!({
        "addon_api": 1,
        "subscriptions": [{"event": "voice.session.closed"}],
        "data": {"max_mb": 8, "tables": [{"name": "xp", "columns": [{"name": "user_id", "type": "text"}]}]},
        "settings": [{"key": "xp_per_minute", "type": "int", "label": "XP per minute", "default": 5}],
        "slots": [{"kind": "member.badge", "name": "level"}],
    })
}

#[tokio::test]
async fn the_manifest_sections_are_shown_before_install_and_recorded_after() {
    let s = setup(
        "slimm-platform-record",
        manifest("1.0.0", &platform_manifest()),
    )
    .await;
    let (_, detail) = s.send("GET", "/space/dock/modules/xp", None).await;
    assert_eq!(detail["addon_api"], 1);
    assert_eq!(detail["subscriptions"], json!(["voice.session.closed"]));
    assert_eq!(detail["settings"][0]["key"], "xp_per_minute");
    assert_eq!(detail["slots"][0]["name"], "level");
    assert_eq!(detail["data"]["max_mb"], 8);

    let installed = s.install("1.0.0", Some(&NEW_CAPS)).await;
    assert_eq!(installed["addon_api"], 1);
    assert_eq!(installed["subscriptions"], json!(["voice.session.closed"]));
    assert_eq!(installed["settings"][0]["default"], 5);
    assert_eq!(installed["data"]["tables"][0]["name"], "xp");
    assert_eq!(installed["approved_host_capabilities"], json!(NEW_CAPS));
}

#[tokio::test]
async fn an_old_manifest_installs_and_answers_without_the_new_fields() {
    let old = json!({"capabilities": ["message.post"]});
    let s = setup("slimm-platform-old", manifest("1.0.0", &old)).await;
    let installed = s.install("1.0.0", None).await;
    for field in ["addon_api", "subscriptions", "settings", "slots", "data"] {
        assert!(installed.get(field).is_none(), "{field} in {installed}");
    }
}

#[tokio::test]
async fn a_manifest_this_host_cannot_serve_is_refused_at_install() {
    let mut future = platform_manifest();
    future["addon_api"] = json!(3);
    let s = setup("slimm-platform-future", manifest("1.0.0", &future)).await;
    let body = json!({ "version": "1.0.0" });
    let (status, error) = s
        .send("POST", "/space/dock/modules/xp/install", Some(body))
        .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert!(error.to_string().contains("add-on API 3"), "{error}");
}

#[tokio::test]
async fn a_new_build_must_be_approved_again_for_each_new_capability() {
    let s = setup(
        "slimm-platform-reask",
        manifest("1.0.0", &platform_manifest()),
    )
    .await;
    s.install("1.0.0", Some(&NEW_CAPS)).await;

    let same = s.install("1.0.0", None).await;
    assert_eq!(same["approved_host_capabilities"], json!(NEW_CAPS));

    for cap in NEW_CAPS {
        let only = [cap];
        s.install("1.0.0", Some(&only)).await;
        *s.current.lock().unwrap() = manifest("1.0.1", &platform_manifest());
        let updated = s.install("1.0.1", None).await;
        assert_eq!(updated["approved_host_capabilities"], json!([]), "{cap}");
        *s.current.lock().unwrap() = manifest("1.0.0", &platform_manifest());
    }
}
