// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A dock install is one write: when recording where a module came from fails,
//! the module is not left installed looking like an official one.

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

const ARTIFACT_BYTES: &[u8] = b"fake wasm bytes for lifecycle test";
const ARTIFACT_SHA256: &str = "f2699cd279b6629b45bd9ff149868dad60f6e4d236eafed4063421286c712f9c";

fn manifest(id: &str, sha256: &str) -> Value {
    json!({
        "schema": 1,
        "id": id,
        "name": id,
        "version": "0.1.0",
        "summary": "a module",
        "artifact": {"kind": "wasm", "path": format!("modules/{id}/0.1.0/module.wasm"), "sha256": sha256},
        "runtime": {"backend": "wasm", "limits": {"memory_mb": 64, "wall_ms": 2000, "fuel": 500000000}},
        "permissions": [{"key": "run", "name": "Run", "description": "run it"}],
        "capabilities": ["command.register"],
        "extension_points": [{"kind": "command", "name": "run", "description": "runs", "permission": "run"}]
    })
}

fn index(ids: &[&str]) -> Value {
    let modules: Vec<Value> = ids
        .iter()
        .map(|id| json!({"id": id, "name": id, "version": "0.1.0", "summary": "a module"}))
        .collect();
    json!({"schema": 1, "modules": modules})
}

/// Serves `ids` under `prefix`, each with a good manifest and the shared artifact.
fn registry_routes(mut router: Router, prefix: &str, ids: &[&'static str]) -> Router {
    let idx = index(ids);
    router = router.route(
        &format!("{prefix}/index.json"),
        get(move || async move { axum::Json(idx) }),
    );
    for id in ids {
        let m = manifest(id, ARTIFACT_SHA256);
        router = router
            .route(
                &format!("{prefix}/modules/{id}/manifest.json"),
                get(move || async move { axum::Json(m) }),
            )
            .route(
                &format!("{prefix}/modules/{id}/0.1.0/module.wasm"),
                get(|| async { ARTIFACT_BYTES.to_vec() }),
            );
    }
    router
}

/// The official registry at `/`, and community repos under `/<owner>/<repo>/main/`.
async fn fake_upstream() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}/", listener.local_addr().unwrap());
    let mut router = registry_routes(Router::new(), "", &["code-exec"]);
    router = registry_routes(router, "/acme/mods/main", &["code-exec", "extra"]);
    router = registry_routes(router, "/zed/mods/main", &["extra"]);
    router = router
        .route(
            "/bad/repo/main/index.json",
            get(|| async { "this is not an index" }),
        )
        .route(
            "/acme/mods/main/modules/sneaky/manifest.json",
            get(|| async { axum::Json(manifest("someone-else", ARTIFACT_SHA256)) }),
        )
        .route(
            "/acme/mods/main/modules/tampered/manifest.json",
            get(|| async { axum::Json(manifest("tampered", &"0".repeat(64))) }),
        )
        .route(
            "/acme/mods/main/modules/tampered/0.1.0/module.wasm",
            get(|| async { ARTIFACT_BYTES.to_vec() }),
        );
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    base
}

struct World {
    router: Router,
    store: Store,
    admin: String,
    pool: sqlx::SqlitePool,
    _guard: support::TestDbGuard,
}

async fn world(name: &str) -> World {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool.clone());
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    store
        .create_role("everyone", view_send, true)
        .await
        .unwrap();
    let admin_role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = store.create_user("root", "Root").await.unwrap();
    store.assign_role(admin.id, admin_role).await.unwrap();
    let admin_token = store
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token;
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
        dock: Dock::for_test(&fake_upstream().await),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    });
    World {
        router,
        store,
        admin: admin_token,
        pool,
        _guard: guard,
    }
}

impl World {
    async fn call(
        &self,
        method: &str,
        uri: &str,
        token: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let mut builder = Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("Bearer {token}"));
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

    async fn add_source(&self, repo: &str) -> String {
        let (status, body) = self
            .call(
                "POST",
                "/space/dock/sources",
                &self.admin,
                Some(json!({ "repo": repo })),
            )
            .await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        body["id"].as_str().unwrap().to_owned()
    }

    async fn install(&self, source: Option<&str>, id: &str) -> (StatusCode, Value) {
        let query = source.map(|s| format!("?source={s}")).unwrap_or_default();
        self.call(
            "POST",
            &format!("/space/dock/modules/{id}/install{query}"),
            &self.admin,
            Some(json!({ "version": "0.1.0" })),
        )
        .await
    }
}

/// Fault injection: the third write of the install (the source) fails, as a db
/// error or a crash between the calls would. The install answers an error, so
/// the admin believes nothing was installed.
#[tokio::test]
async fn a_failed_source_write_does_not_leave_a_community_module_looking_official() {
    let w = world("slimm-dock-install-atomic").await;
    let acme = w.add_source("acme/mods").await;
    sqlx::query(
        "CREATE TRIGGER fail_source BEFORE UPDATE OF source_repo ON installed_modules \
         BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
    )
    .execute(&w.pool)
    .await
    .unwrap();

    let (status, body) = w.install(Some(&acme), "extra").await;
    assert!(
        status.is_server_error(),
        "install should report the failure: {status} {body}"
    );

    let left = w.store.installed_module("extra").await.unwrap();
    if let Some(m) = &left {
        assert_eq!(
            m.source_repo.as_deref(),
            Some("acme/mods"),
            "install failed with {status} yet left `extra` installed with source_repo = {:?}, i.e. reads as official",
            m.source_repo
        );
    }
}
