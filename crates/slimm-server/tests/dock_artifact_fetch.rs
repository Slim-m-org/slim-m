// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Dock's fetches: an artifact larger than a slow link moves in a few
//! seconds still installs, and a manifest naming a backend this host cannot run
//! is refused without registering anything.

use axum::Router;
use axum::body::Body;
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
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

const SHA_3MB_ZEROS: &str = "35bce4eae54ec8e6cc2868baa8d157914d6ae2858811b4cc0c078c94460fa26f";
const SHA_FAKE: &str = "f2699cd279b6629b45bd9ff149868dad60f6e4d236eafed4063421286c712f9c";

fn manifest(backend: &str, kind: &str, sha: &str) -> Value {
    json!({
        "schema": 1, "id": "code-exec", "name": "Code Blocks", "version": "0.1.0",
        "summary": "runs code",
        "artifact": {"kind": kind, "path": "modules/code-exec/0.1.0/module.wasm", "sha256": sha},
        "runtime": {"backend": backend, "limits": {"memory_mb": 64, "wall_ms": 2000, "fuel": 500000000}},
        "permissions": [{"key": "run", "name": "Execute", "description": "run a snippet"}],
        "capabilities": ["command.register", "message.post"],
        "extension_points": [{"kind": "command", "name": "run", "description": "runs it", "permission": "run"}]
    })
}

const INDEX: &str = r#"{"schema":1,"modules":[{"id":"code-exec","name":"Code Blocks","version":"0.1.0","summary":"runs code"}]}"#;

async fn registry(m: Value, slow: bool) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let artifact = if slow {
        get(|| async {
            // 3,000,000 bytes at about 400 KB/s (3.2 Mbit/s), a modest home uplink
            let s = futures_util::stream::unfold(0u32, |i| async move {
                if i == 30 {
                    return None;
                }
                tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                Some((Ok::<_, std::io::Error>(vec![0u8; 100_000]), i + 1))
            });
            Body::from_stream(s)
        })
    } else {
        get(|| async { b"fake wasm bytes for lifecycle test".to_vec() })
    };
    let router = Router::new()
        .route(
            "/index.json",
            get(|| async { axum::Json(serde_json::from_str::<Value>(INDEX).unwrap()) }),
        )
        .route(
            "/modules/code-exec/manifest.json",
            get(move || {
                let m = m.clone();
                async move { axum::Json(m) }
            }),
        )
        .route("/modules/code-exec/0.1.0/module.wasm", artifact);
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    format!("http://{addr}/")
}

async fn setup(name: &str, dock: Dock) -> (Router, Store, String, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let s = Store::new(db::connect(&config).await.unwrap());
    let vs = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    s.create_role("everyone", vs, true).await.unwrap();
    let r = s
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = s.create_user("root", "Root").await.unwrap();
    s.assign_role(admin.id, r).await.unwrap();
    let token = s
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token
        .as_str()
        .to_owned();
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
        dock,
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    });
    (router, s, token, guard)
}

async fn install(router: &Router, token: &str) -> StatusCode {
    router
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/space/dock/modules/code-exec/install")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({"version":"0.1.0"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn install_refuses_a_backend_the_host_does_not_provide() {
    let base = registry(manifest("container", "oci-image", SHA_FAKE), false).await;
    let (router, s, token, _g) = setup("dock-fetch-backend", Dock::for_test(&base)).await;
    let status = install(&router, &token).await;
    let installed = s.installed_module("code-exec").await.unwrap().is_some();
    assert_ne!(status, StatusCode::OK, "backend container was accepted");
    assert!(!installed);
}

#[tokio::test]
async fn install_succeeds_for_a_3mb_artifact_over_a_3mbit_link() {
    let base = registry(manifest("wasm", "wasm", SHA_3MB_ZEROS), true).await;
    let (router, _s, token, _g) = setup("dock-fetch-slow", Dock::for_test(&base)).await;
    let status = install(&router, &token).await;
    assert_eq!(status, StatusCode::OK);
}
