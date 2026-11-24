// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Dock installs and enables run one at a time, so two admins cannot both pass a
//! check that the other's write is about to fail, and a withdrawn version is flagged.

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

use crate::support;

const ARTIFACT_BYTES: &[u8] = b"fake wasm bytes for lifecycle test";
const ARTIFACT_SHA256: &str = "f2699cd279b6629b45bd9ff149868dad60f6e4d236eafed4063421286c712f9c";
const IDS: [&str; 6] = ["m0", "m1", "m2", "m3", "m4", "m5"];

fn manifest(id: &str) -> Value {
    json!({
        "schema": 1, "id": id, "name": id, "version": "0.1.0", "summary": "a module",
        "artifact": {"kind": "wasm", "path": format!("modules/{id}/0.1.0/module.wasm"), "sha256": ARTIFACT_SHA256},
        "runtime": {"backend": "wasm", "limits": {"memory_mb": 64, "wall_ms": 2000, "fuel": 500000000}},
        "permissions": [{"key": "go", "name": "Go", "description": "go"}],
        "capabilities": ["command.register"],
        "extension_points": [
            {"kind": "command", "name": "run", "description": "runs", "permission": "go"},
            {"kind": "slash-command", "name": "go", "description": "goes", "permission": "go", "command": "run"}
        ]
    })
}

async fn upstream(withdrawn: bool) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}/", listener.local_addr().unwrap());
    let rows: Vec<Value> = IDS
        .iter()
        .map(|id| {
            let mut row = json!({"id": id, "name": id, "version": "0.1.0", "summary": "a module"});
            if withdrawn && *id == "m0" {
                row["withdrawn"] = json!(["0.1.0"]);
                row["withdrawn_reason"] = json!("forged results, update now");
            }
            row
        })
        .collect();
    let index = json!({"schema": 1, "modules": rows});
    let mut router =
        Router::new().route("/index.json", get(move || async move { axum::Json(index) }));
    for id in IDS {
        let m = manifest(id);
        router = router
            .route(
                &format!("/modules/{id}/manifest.json"),
                get(move || async move { axum::Json(m) }),
            )
            .route(
                &format!("/modules/{id}/0.1.0/module.wasm"),
                get(|| async { ARTIFACT_BYTES.to_vec() }),
            );
    }
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    base
}

struct World {
    router: Router,
    admin: String,
    _guard: support::TestDbGuard,
}

async fn world(name: &str, withdrawn: bool) -> World {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool);
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    store
        .create_role("everyone", view_send, true)
        .await
        .unwrap();
    let role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = store.create_user("root", "Root").await.unwrap();
    store.assign_role(admin.id, role).await.unwrap();
    let admin = store.open_session(admin.id, "laptop").await.unwrap();
    let router = support::app::builder(store)
        .dock(Dock::for_test(&upstream(withdrawn).await))
        .router();
    World {
        router,
        admin: admin.access_token,
        _guard: guard,
    }
}

impl World {
    async fn call(&self, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
        let mut builder = Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("Bearer {}", self.admin));
        let body = match body {
            Some(v) => {
                builder = builder.header("content-type", "application/json");
                Body::from(v.to_string())
            }
            None => Body::empty(),
        };
        let response = self
            .router
            .clone()
            .oneshot(builder.body(body).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    async fn install(&self, id: &str) {
        let uri = format!("/space/dock/modules/{id}/install");
        let (status, body) = self
            .call("POST", &uri, Some(json!({"version": "0.1.0"})))
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
    }

    async fn set(&self, id: &str, verb: &str) -> StatusCode {
        let uri = format!("/space/dock/modules/{id}/{verb}");
        self.call("POST", &uri, None).await.0
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn racing_enables_of_modules_with_one_slash_keyword_let_only_one_through() {
    let w = world("slimm-dock-serialized-enable", false).await;
    for id in IDS {
        w.install(id).await;
        assert_eq!(w.set(id, "disable").await, StatusCode::OK);
    }
    let w = std::sync::Arc::new(w);
    let racers = IDS.map(|id| {
        let w = std::sync::Arc::clone(&w);
        tokio::spawn(async move { w.set(id, "enable").await })
    });
    let statuses = futures_util::future::try_join_all(racers).await.unwrap();
    let enabled = statuses.iter().filter(|s| **s == StatusCode::OK).count();
    assert_eq!(enabled, 1, "{statuses:?}");
}

#[tokio::test]
async fn a_withdrawn_installed_version_is_flagged_with_the_registrys_reason() {
    let w = world("slimm-dock-withdrawn", true).await;
    w.install("m0").await;
    w.install("m1").await;
    let (status, body) = w.call("GET", "/space/dock/installed", None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let row = |id: &str| {
        body.as_array()
            .unwrap()
            .iter()
            .find(|m| m["id"] == id)
            .unwrap()
            .clone()
    };
    assert_eq!(row("m0")["withdrawn_reason"], "forged results, update now");
    assert!(row("m1").get("withdrawn_reason").is_none());
    let (_, listing) = w.call("GET", "/space/dock/modules", None).await;
    assert_eq!(listing[0]["withdrawn"], json!(["0.1.0"]));
}
