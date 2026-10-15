// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Installing a module that declares `net.fetch` through the Dock: the hosts
//! the admin saw are what gets recorded, local addresses need the separate
//! second approval, and a new host list must be approved again.

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
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

const ARTIFACT_BYTES: &[u8] = b"fake wasm bytes for lifecycle test";
const ARTIFACT_SHA256: &str = "f2699cd279b6629b45bd9ff149868dad60f6e4d236eafed4063421286c712f9c";

fn manifest(hosts: &[&str], local: bool) -> Value {
    json!({
        "schema": 1,
        "id": "homelab",
        "name": "Homelab",
        "version": "0.1.0",
        "summary": "checks the servers",
        "artifact": {"kind": "wasm", "path": "modules/homelab/0.1.0/module.wasm", "sha256": ARTIFACT_SHA256},
        "runtime": {"backend": "wasm"},
        "permissions": [{"key": "run", "name": "Check", "description": "check status"}],
        "capabilities": ["net.fetch"],
        "network": {"hosts": hosts, "local": local},
        "extension_points": [{"kind": "command", "name": "status", "description": "status", "permission": "run"}]
    })
}

/// Serves `served`, swappable mid-test to publish a new manifest.
async fn registry(served: Arc<Mutex<Value>>) -> String {
    let index = json!({"schema": 1, "modules": [
        {"id": "homelab", "name": "Homelab", "version": "0.1.0", "summary": "checks the servers"}
    ]});
    let router = Router::new()
        .route("/index.json", get(move || async move { axum::Json(index) }))
        .route(
            "/modules/homelab/manifest.json",
            get(|State(m): State<Arc<Mutex<Value>>>| async move {
                axum::Json(m.lock().unwrap().clone())
            }),
        )
        .route(
            "/modules/homelab/0.1.0/module.wasm",
            get(|| async { ARTIFACT_BYTES.to_vec() }),
        )
        .with_state(served);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}/", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    base
}

struct Harness {
    router: Router,
    token: String,
    served: Arc<Mutex<Value>>,
    _guard: support::TestDbGuard,
}

async fn harness(name: &str) -> Harness {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let s = Store::new(db::connect(&config).await.expect("connect + migrate"));
    s.create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
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
    let served = Arc::new(Mutex::new(manifest(&["jellyfin.lan:8096"], true)));
    let dock = Dock::for_test(&registry(served.clone()).await);
    let router = http::router(AppState {
        store: s,
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
    Harness {
        router,
        token,
        served,
        _guard: guard,
    }
}

impl Harness {
    async fn install(&self, body: Value) -> (StatusCode, Value) {
        let request = Request::builder()
            .method("POST")
            .uri("/space/dock/modules/homelab/install")
            .header("authorization", format!("Bearer {}", self.token))
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        let response = self.router.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }
}

#[tokio::test]
async fn the_manifest_shows_its_hosts_before_install() {
    let h = harness("slimm-dock-net-manifest").await;
    let request = Request::builder()
        .uri("/space/dock/modules/homelab")
        .header("authorization", format!("Bearer {}", h.token))
        .body(Body::empty())
        .unwrap();
    let response = h.router.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        body["network"],
        json!({"hosts": ["jellyfin.lan:8096"], "local": true})
    );
}

#[tokio::test]
async fn approving_net_fetch_records_the_hosts_and_local_needs_its_own_yes() {
    let h = harness("slimm-dock-net-approve").await;
    let (status, plain) = h
        .install(json!({"version": "0.1.0", "approved_host_capabilities": ["net.fetch"]}))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(plain["network_hosts"], json!(["jellyfin.lan:8096"]));
    assert_eq!(plain["local_network_approved"], json!(false));

    let (_, local) = h
        .install(json!({
            "version": "0.1.0",
            "approved_host_capabilities": ["net.fetch"],
            "approve_local_network": true
        }))
        .await;
    assert_eq!(local["local_network_approved"], json!(true));

    let (_, kept) = h.install(json!({"version": "0.1.0"})).await;
    assert_eq!(kept["approved_host_capabilities"], json!(["net.fetch"]));
    assert_eq!(
        kept["local_network_approved"],
        json!(true),
        "an update keeps both"
    );
}

#[tokio::test]
async fn without_net_fetch_no_hosts_are_recorded_and_local_cannot_be_approved() {
    let h = harness("slimm-dock-net-unapproved").await;
    let (status, bare) = h.install(json!({"version": "0.1.0"})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(bare["network_hosts"], json!([]));
    let (status, _) = h
        .install(json!({"version": "0.1.0", "approved_host_capabilities": [], "approve_local_network": true}))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_manifest_that_did_not_ask_for_local_cannot_be_given_it() {
    let h = harness("slimm-dock-net-not-local").await;
    *h.served.lock().unwrap() = manifest(&["api.example.com"], false);
    let (status, _) = h
        .install(json!({
            "version": "0.1.0",
            "approved_host_capabilities": ["net.fetch"],
            "approve_local_network": true
        }))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn new_hosts_drop_the_approvals_until_the_admin_approves_again() {
    let h = harness("slimm-dock-net-new-hosts").await;
    h.install(json!({
        "version": "0.1.0",
        "approved_host_capabilities": ["net.fetch"],
        "approve_local_network": true
    }))
    .await;
    *h.served.lock().unwrap() = manifest(&["jellyfin.lan:8096", "evil.example"], true);

    let (status, updated) = h.install(json!({"version": "0.1.0"})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["approved_host_capabilities"], json!([]));
    assert_eq!(updated["network_hosts"], json!([]));
    assert_eq!(updated["local_network_approved"], json!(false));
}
