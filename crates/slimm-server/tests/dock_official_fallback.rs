// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The official module registry across the move from `NC1107/slim-addons` to
//! `Slim-m-org/slim-addons`: the Dock tries the configured slug, then the
//! other official one, only when the first answers 404 or a redirect, and
//! never follows the redirect itself.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use axum::response::IntoResponse;
use axum::routing::get;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::dock::Dock;
use slimm_server::permissions::Permissions;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

const ORG: &str = "/Slim-m-org/slim-addons/main";
const LEGACY: &str = "/NC1107/slim-addons/main";
const ARTIFACT_BYTES: &[u8] = b"fake wasm bytes for lifecycle test";
const ARTIFACT_SHA256: &str = "f2699cd279b6629b45bd9ff149868dad60f6e4d236eafed4063421286c712f9c";

fn manifest(id: &str) -> Value {
    json!({
        "schema": 1,
        "id": id,
        "name": id,
        "version": "0.1.0",
        "summary": "a module",
        "artifact": {"kind": "wasm", "path": format!("modules/{id}/0.1.0/module.wasm"), "sha256": ARTIFACT_SHA256},
        "runtime": {"backend": "wasm", "limits": {"memory_mb": 64, "wall_ms": 2000, "fuel": 500000000}},
        "permissions": [{"key": "run", "name": "Run", "description": "run it"}],
        "capabilities": ["command.register"],
        "extension_points": [{"kind": "command", "name": "run", "description": "runs", "permission": "run"}]
    })
}

/// Serves one module `id` as a whole registry under `prefix`.
fn registry(router: Router, prefix: &str, id: &'static str) -> Router {
    let index = json!({"schema": 1, "modules": [
        {"id": id, "name": id, "version": "0.1.0", "summary": "a module"}
    ]});
    router
        .route(
            &format!("{prefix}/index.json"),
            get(move || async move { axum::Json(index) }),
        )
        .route(
            &format!("{prefix}/modules/{id}/manifest.json"),
            get(move || async move { axum::Json(manifest(id)) }),
        )
        .route(
            &format!("{prefix}/modules/{id}/0.1.0/module.wasm"),
            get(|| async { ARTIFACT_BYTES.to_vec() }),
        )
}

/// Answers every GET under `prefix` with a 301 to `location`, the way GitHub
/// answers for a transferred repo.
fn moved(router: Router, prefix: &str, location: &'static str) -> Router {
    router.route(
        &format!("{prefix}/{{*rest}}"),
        get(move || async move {
            (
                StatusCode::MOVED_PERMANENTLY,
                [(header::LOCATION, location)],
            )
                .into_response()
        }),
    )
}

async fn serve(router: Router) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let root = format!("http://{}/", listener.local_addr().unwrap());
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    root
}

struct World {
    router: Router,
    admin: String,
    _guard: support::TestDbGuard,
}

async fn world(name: &str, upstream: Router, addons_repo: Option<&str>) -> World {
    let (path, guard) = support::TestDbGuard::new(name);
    let mut config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    if let Some(repo) = addons_repo {
        config.addons_repo = repo.to_owned();
    }
    let store = slimm_server::store::Store::new(db::connect(&config).await.unwrap());
    let admin_role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = store.create_user("root", "Root").await.unwrap();
    store.assign_role(admin.id, admin_role).await.unwrap();
    let admin_token = store.open_session(admin.id, "laptop").await.unwrap();
    let dock = Dock::for_test_rooted(&serve(upstream).await, &config);
    let router = support::app::builder(store).dock(dock).router();
    World {
        router,
        admin: admin_token.access_token,
        _guard: guard,
    }
}

impl World {
    async fn call(&self, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
        let request = Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("Bearer {}", self.admin))
            .header("content-type", "application/json")
            .body(body.map_or_else(Body::empty, |v| Body::from(v.to_string())))
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

    async fn listed_ids(&self) -> Vec<String> {
        let (status, body) = self.call("GET", "/space/dock/modules", None).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body.as_array()
            .unwrap()
            .iter()
            .map(|m| m["id"].as_str().unwrap().to_owned())
            .collect()
    }
}

#[tokio::test]
async fn before_the_move_the_default_falls_back_to_the_legacy_slug() {
    let upstream = registry(Router::new(), LEGACY, "legacy-mod");
    let w = world("slimm-dock-fallback-before", upstream, None).await;

    assert_eq!(w.listed_ids().await, vec!["legacy-mod"]);
    let (status, body) = w
        .call(
            "POST",
            "/space/dock/modules/legacy-mod/install",
            Some(json!({"version": "0.1.0"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

#[tokio::test]
async fn after_the_move_the_org_slug_wins_over_the_legacy_one() {
    let upstream = registry(Router::new(), ORG, "org-mod");
    let upstream = registry(upstream, LEGACY, "legacy-mod");
    let w = world("slimm-dock-fallback-after", upstream, None).await;

    assert_eq!(w.listed_ids().await, vec!["org-mod"]);
}

#[tokio::test]
async fn a_pinned_legacy_slug_answering_a_redirect_falls_back_without_following_it() {
    let upstream = registry(Router::new(), ORG, "org-mod");
    let upstream = registry(upstream, "/followed/main", "followed-mod");
    let upstream = moved(upstream, LEGACY, "/followed/main/index.json");
    let w = world(
        "slimm-dock-fallback-redirect",
        upstream,
        Some("NC1107/slim-addons"),
    )
    .await;

    assert_eq!(w.listed_ids().await, vec!["org-mod"]);
}

#[tokio::test]
async fn an_outage_on_the_first_slug_is_reported_rather_than_masked() {
    let legacy_hits = Arc::new(AtomicUsize::new(0));
    let hits = legacy_hits.clone();
    let upstream = Router::new()
        .route(
            &format!("{ORG}/index.json"),
            get(|| async { StatusCode::INTERNAL_SERVER_ERROR }),
        )
        .route(
            &format!("{LEGACY}/index.json"),
            get(move || async move {
                hits.fetch_add(1, Ordering::SeqCst);
                StatusCode::OK
            }),
        );
    let w = world("slimm-dock-fallback-outage", upstream, None).await;

    let (status, _) = w.call("GET", "/space/dock/modules", None).await;
    assert_ne!(status, StatusCode::OK);
    assert_eq!(legacy_hits.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn an_operators_own_registry_has_no_fallback() {
    let upstream = registry(Router::new(), LEGACY, "legacy-mod");
    let w = world("slimm-dock-fallback-custom", upstream, Some("acme/mods")).await;

    let (status, body) = w.call("GET", "/space/dock/modules", None).await;
    assert_ne!(status, StatusCode::OK, "{body}");
}

#[tokio::test]
async fn neither_official_slug_can_be_added_as_a_community_source() {
    let w = world("slimm-dock-fallback-source", Router::new(), None).await;

    for repo in ["Slim-m-org/slim-addons", "nc1107/slim-addons"] {
        let (status, body) = w
            .call("POST", "/space/dock/sources", Some(json!({"repo": repo})))
            .await;
        assert_eq!(status, StatusCode::CONFLICT, "{repo}: {body}");
    }
}
