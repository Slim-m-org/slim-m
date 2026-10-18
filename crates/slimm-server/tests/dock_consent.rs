// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What an admin's yes is for: the commit the Dock reads, the manifest they
//! reviewed, and the powers a new build or a changed schedule must ask for
//! again. Plus the operator's local `dev` source.

use std::path::Path;
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
use support::wasm_fixtures::{canned_ok_wasm, sha256_hex};

const PINNED: &str = "3f9c1c0b1a2d4e5f60718293a4b5c6d7e8f90a1b";

fn manifest(hosts: &[&str], every: u32, wasm: &[u8]) -> Value {
    json!({
        "schema": 1,
        "id": "digest",
        "name": "Digest",
        "version": "0.1.0",
        "summary": "posts a digest",
        "artifact": {"kind": "wasm", "path": "modules/digest/0.1.0/module.wasm", "sha256": sha256_hex(wasm)},
        "runtime": {"backend": "wasm"},
        "permissions": [{"key": "run", "name": "Run", "description": "run"}],
        "capabilities": ["net.fetch", "schedule", "kv.store"],
        "network": {"hosts": hosts, "local": false},
        "schedules": [{"command": "post", "every_minutes": every}],
        "extension_points": [{"kind": "command", "name": "post", "description": "post", "permission": "run"}]
    })
}

#[derive(Clone)]
struct Served {
    /// What the pinned commit holds.
    pinned: Arc<Mutex<Value>>,
    /// What `main` holds, which moves.
    main: Arc<Mutex<Value>>,
    wasm: Arc<Mutex<Vec<u8>>>,
    index_ref: Arc<Mutex<Option<String>>>,
}

async fn registry(served: Served) -> String {
    let router = Router::new()
        .route(
            "/index.json",
            get(|State(s): State<Served>| async move {
                let mut entry = json!({"id": "digest", "name": "Digest", "version": "0.1.0", "summary": "posts a digest"});
                if let Some(reference) = s.index_ref.lock().unwrap().clone() {
                    entry["ref"] = json!(reference);
                }
                axum::Json(json!({"schema": 1, "modules": [entry]}))
            }),
        )
        .route(
            "/modules/digest/manifest.json",
            get(|State(s): State<Served>| async move { axum::Json(s.main.lock().unwrap().clone()) }),
        )
        .route(
            &format!("/{PINNED}/modules/digest/manifest.json"),
            get(|State(s): State<Served>| async move { axum::Json(s.pinned.lock().unwrap().clone()) }),
        )
        .route(
            "/modules/digest/0.1.0/module.wasm",
            get(|State(s): State<Served>| async move { s.wasm.lock().unwrap().clone() }),
        )
        .route(
            &format!("/{PINNED}/modules/digest/0.1.0/module.wasm"),
            get(|State(s): State<Served>| async move { s.wasm.lock().unwrap().clone() }),
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
    served: Served,
    store: Store,
    _guard: support::TestDbGuard,
}

async fn harness(name: &str, dev_dir: Option<&Path>) -> Harness {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let admin_role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = store.create_user("root", "Root").await.unwrap();
    store.assign_role(admin.id, admin_role).await.unwrap();
    let token = store
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let wasm = canned_ok_wasm("done");
    let doc = manifest(&["api.example.com"], 1440, &wasm);
    let served = Served {
        pinned: Arc::new(Mutex::new(doc.clone())),
        main: Arc::new(Mutex::new(doc)),
        wasm: Arc::new(Mutex::new(wasm)),
        index_ref: Arc::new(Mutex::new(None)),
    };
    let base = registry(served.clone()).await;
    let dock = match dev_dir {
        Some(dir) => Dock::for_test_with_dev(&base, dir),
        None => Dock::for_test(&base),
    };
    let router = http::router(AppState {
        store: store.clone(),
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
        store,
        _guard: guard,
    }
}

impl Harness {
    async fn call(&self, method: &str, uri: &str, body: Value) -> (StatusCode, Value) {
        let request = Request::builder()
            .method(method)
            .uri(uri)
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

    async fn install(&self, body: Value) -> (StatusCode, Value) {
        self.call("POST", "/space/dock/modules/digest/install", body)
            .await
    }

    async fn digest(&self) -> String {
        let (_, m) = self
            .call("GET", "/space/dock/modules/digest", Value::Null)
            .await;
        m["review_digest"].as_str().unwrap().to_owned()
    }
}

const FULL: [&str; 3] = ["net.fetch", "schedule", "kv.store"];

#[tokio::test]
async fn a_version_with_a_ref_is_read_from_that_commit_not_from_main() {
    let h = harness("slimm-dockc-pin", None).await;
    *h.served.index_ref.lock().unwrap() = Some(PINNED.to_owned());
    *h.served.main.lock().unwrap() = manifest(&["evil.example"], 5, &canned_ok_wasm("done"));

    let (_, shown) = h
        .call("GET", "/space/dock/modules/digest", Value::Null)
        .await;
    assert_eq!(shown["network"]["hosts"], json!(["api.example.com"]));
    let (status, installed) = h
        .install(json!({"version": "0.1.0", "approved_host_capabilities": FULL}))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(installed["network_hosts"], json!(["api.example.com"]));
}

#[tokio::test]
async fn without_a_ref_the_install_still_works_from_main() {
    let h = harness("slimm-dockc-noref", None).await;
    let (status, installed) = h.install(json!({"version": "0.1.0"})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(installed["version"], json!("0.1.0"));
}

#[tokio::test]
async fn a_manifest_that_changed_since_review_is_refused() {
    let h = harness("slimm-dockc-digest", None).await;
    let reviewed = h.digest().await;
    *h.served.main.lock().unwrap() = manifest(
        &["api.example.com", "evil.example"],
        1440,
        &canned_ok_wasm("done"),
    );

    let (status, body) = h
        .install(json!({"version": "0.1.0", "approved_host_capabilities": FULL, "reviewed_digest": reviewed}))
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert!(
        body["error"]
            .as_str()
            .unwrap()
            .contains("reopen it in the Dock"),
        "{body}"
    );
    assert!(h.store.installed_module("digest").await.unwrap().is_none());

    let fresh = h.digest().await;
    assert_ne!(fresh, reviewed);
    let (status, _) = h
        .install(json!({"version": "0.1.0", "approved_host_capabilities": FULL, "reviewed_digest": fresh}))
        .await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn a_changed_schedule_interval_must_be_approved_again() {
    let h = harness("slimm-dockc-interval", None).await;
    h.install(json!({"version": "0.1.0", "approved_host_capabilities": FULL}))
        .await;
    *h.served.main.lock().unwrap() = manifest(&["api.example.com"], 5, &canned_ok_wasm("done"));

    let (_, updated) = h.install(json!({"version": "0.1.0"})).await;
    let kept = updated["approved_host_capabilities"].as_array().unwrap();
    assert!(!kept.contains(&json!("schedule")), "{updated}");
    assert!(
        kept.contains(&json!("net.fetch")) && kept.contains(&json!("kv.store")),
        "{updated}"
    );
    assert_eq!(updated["schedules"][0]["every_minutes"], json!(5));
}

#[tokio::test]
async fn a_new_build_of_a_fetching_or_scheduled_module_asks_again() {
    let h = harness("slimm-dockc-build", None).await;
    h.install(json!({"version": "0.1.0", "approved_host_capabilities": FULL}))
        .await;
    let other = canned_ok_wasm("something else");
    *h.served.wasm.lock().unwrap() = other.clone();
    *h.served.main.lock().unwrap() = manifest(&["api.example.com"], 1440, &other);

    let (_, updated) = h.install(json!({"version": "0.1.0"})).await;
    assert_eq!(updated["approved_host_capabilities"], json!(["kv.store"]));

    let (_, approved) = h
        .install(json!({"version": "0.1.0", "approved_host_capabilities": FULL}))
        .await;
    assert_eq!(
        approved["approved_host_capabilities"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
}

fn write_dev_module(dir: &Path, wasm: &[u8]) {
    let module = dir.join("modules/digest");
    std::fs::create_dir_all(module.join("0.1.0")).unwrap();
    let doc = manifest(&["api.example.com"], 1440, wasm);
    std::fs::write(module.join("manifest.json"), doc.to_string()).unwrap();
    std::fs::write(module.join("0.1.0/module.wasm"), wasm).unwrap();
    std::fs::write(
        dir.join("index.json"),
        json!({"schema": 1, "modules": [{"id": "digest", "name": "Digest", "version": "0.1.0", "summary": "posts a digest"}]}).to_string(),
    )
    .unwrap();
}

#[tokio::test]
async fn the_dev_source_is_absent_without_the_flag() {
    let h = harness("slimm-dockc-dev-off", None).await;
    let (status, _) = h
        .call("GET", "/space/dock/modules?source=dev", Value::Null)
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = h.install(json!({"version": "0.1.0"})).await;
    assert_eq!(status, StatusCode::OK, "the official source is unaffected");
    let (_, sources) = h.call("GET", "/space/dock/sources", Value::Null).await;
    assert!(
        sources
            .as_array()
            .unwrap()
            .iter()
            .all(|s| s["id"] != json!("dev"))
    );
}

#[tokio::test]
async fn the_dev_source_installs_and_reinstalls_an_overwritten_build_without_a_push() {
    let dir = std::env::temp_dir().join(format!("slimm-dockc-dev-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    write_dev_module(&dir, &canned_ok_wasm("first"));
    let h = harness("slimm-dockc-dev-on", Some(&dir)).await;

    let (_, sources) = h.call("GET", "/space/dock/sources", Value::Null).await;
    let dev = sources
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == json!("dev"))
        .unwrap();
    assert_eq!(dev["local"], json!(true));
    assert_eq!(dev["official"], json!(false));

    let (status, listing) = h
        .call("GET", "/space/dock/modules?source=dev", Value::Null)
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(listing[0]["id"], json!("digest"));
    let (status, first) = h
        .call(
            "POST",
            "/space/dock/modules/digest/install?source=dev",
            json!({"version": "0.1.0"}),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{first}");
    assert_eq!(first["source_repo"], json!("local/dev"));

    write_dev_module(&dir, &canned_ok_wasm("second"));
    let (status, second) = h
        .call(
            "POST",
            "/space/dock/modules/digest/install?source=dev",
            json!({"version": "0.1.0"}),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{second}");
    assert_ne!(first["artifact_sha256"], second["artifact_sha256"]);
    std::fs::remove_dir_all(&dir).unwrap();
}
