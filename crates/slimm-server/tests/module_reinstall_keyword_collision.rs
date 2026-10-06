// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Re-installing an enabled module re-checks its slash keywords: an update
//! may not take a keyword another enabled module already owns.

use std::sync::{Arc, Mutex};

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::routing::get;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::dock::Dock;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModuleRuntimeLimits, Store,
};
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;
use support::wasm_fixtures::sha256_hex;

const ARTIFACT: &[u8] = b"fake wasm bytes for a keyword test";

type Keyword = Arc<Mutex<&'static str>>;

fn manifest(keyword: &str) -> Value {
    json!({
        "schema": 1,
        "id": "newdice",
        "name": "New Dice",
        "version": "0.1.0",
        "summary": "rolls",
        "artifact": {
            "kind": "wasm",
            "path": "modules/newdice/0.1.0/module.wasm",
            "sha256": sha256_hex(ARTIFACT)
        },
        "runtime": {"backend": "wasm", "limits": {"memory_mb": 64, "wall_ms": 2000, "fuel": 500000000}},
        "permissions": [{"key": "use", "name": "Use", "description": "use it"}],
        "capabilities": [],
        "extension_points": [
            {"kind": "command", "name": "run", "description": "runs", "permission": "use"},
            {"kind": "slash-command", "name": keyword, "description": "slash", "permission": "use", "command": "run"}
        ]
    })
}

/// A registry whose one module claims whatever keyword `keyword` holds when asked.
async fn registry(keyword: Keyword) -> String {
    async fn index() -> axum::Json<Value> {
        axum::Json(json!({ "schema": 1, "modules": [] }))
    }
    async fn serve_manifest(State(keyword): State<Keyword>) -> axum::Json<Value> {
        let current = *keyword.lock().unwrap();
        axum::Json(manifest(current))
    }
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}/", listener.local_addr().unwrap());
    let router = Router::new()
        .route("/index.json", get(index))
        .route("/modules/newdice/manifest.json", get(serve_manifest))
        .route(
            "/modules/newdice/0.1.0/module.wasm",
            get(|| async { ARTIFACT.to_vec() }),
        )
        .with_state(keyword);
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    base
}

async fn call(router: &Router, token: &str, uri: &str, body: Option<Value>) -> StatusCode {
    let builder = Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    let request = match body {
        Some(body) => builder
            .header("content-type", "application/json")
            .body(Body::from(body.to_string())),
        None => builder.body(Body::empty()),
    };
    router
        .clone()
        .oneshot(request.unwrap())
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn updating_an_enabled_module_to_a_taken_keyword_is_refused() {
    let (path, _guard) = support::TestDbGuard::new("slimm-reinstall-keyword");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let s = Store::new(db::connect(&config).await.expect("connect + migrate"));
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    s.create_role("everyone", view_send, true).await.unwrap();
    let admin_role = s
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = s.create_user("root", "Root").await.unwrap();
    s.assign_role(admin.id, admin_role).await.unwrap();
    let token = s
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token;

    let keyword: Keyword = Arc::new(Mutex::new("roll"));
    let router = http::router(AppState {
        store: s.clone(),
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: VoiceService::disabled(),
        media: Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: Dock::for_test(&registry(keyword.clone()).await),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    });
    let install = "/space/dock/modules/newdice/install";
    let version = Some(json!({ "version": "0.1.0" }));

    assert_eq!(call(&router, &token, install, version.clone()).await, 200);
    assert_eq!(
        call(&router, &token, "/space/dock/modules/newdice/enable", None).await,
        200
    );
    let points = [
        ModuleExtensionPointSpec {
            kind: "slash-command",
            name: "poll",
            description: None,
            permission: Some("use"),
            command: Some("run"),
            language: None,
        },
        ModuleExtensionPointSpec {
            kind: "command",
            name: "run",
            description: None,
            permission: Some("use"),
            command: None,
            language: None,
        },
    ];
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "poll",
            name: "poll",
            version: "1.0.0",
            artifact_sha256: "00",
            approved_capabilities: &[],
            runtime_limits: &ModuleRuntimeLimits::default(),
            permissions: &[],
            extension_points: &points,
        },
        b"stub-artifact",
    )
    .await
    .unwrap();
    assert_eq!(
        call(&router, &token, "/space/dock/modules/poll/enable", None).await,
        200
    );

    *keyword.lock().unwrap() = "POLL";
    assert_eq!(
        call(&router, &token, install, version).await,
        StatusCode::CONFLICT
    );
}
