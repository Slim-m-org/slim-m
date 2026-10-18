// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Community module sources beside the official one (decision 0045): admin
//! only, slug-only, validated like the official source, one owner per module
//! id, and removal leaving installed modules alone.

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
    member: String,
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
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
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
    let member = store.create_user("nia", "Nia").await.unwrap();
    let admin_token = store
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let member_token = store
        .open_session(member.id, "phone")
        .await
        .unwrap()
        .access_token;
    let router = support::app::builder(store.clone())
        .dock(Dock::for_test(&fake_upstream().await))
        .router();
    World {
        router,
        store,
        admin: admin_token,
        member: member_token,
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

#[tokio::test]
async fn only_an_admin_may_read_add_or_remove_sources() {
    let w = world("slimm-dock-sources-admin-only").await;
    let id = w.add_source("acme/mods").await;
    let cases = [
        ("GET", "/space/dock/sources".to_owned(), None),
        (
            "POST",
            "/space/dock/sources".to_owned(),
            Some(json!({"repo": "acme/other"})),
        ),
        ("DELETE", format!("/space/dock/sources/{id}"), None),
        ("GET", format!("/space/dock/modules?source={id}"), None),
    ];
    for (method, uri, body) in cases {
        let (status, _) = w.call(method, &uri, &w.member, body).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{method} {uri}");
    }
    assert_eq!(w.store.list_dock_sources().await.unwrap().len(), 1);
}

#[tokio::test]
async fn a_source_must_be_a_repo_slug_on_the_fixed_host() {
    let w = world("slimm-dock-sources-ssrf").await;
    for bad in [
        "https://evil.example/acme/mods",
        "http://127.0.0.1:8080/x",
        "127.0.0.1:8080/x",
        "169.254.169.254/latest",
        "acme/../etc",
        "acme/mods/extra",
        "acme",
        "",
        "acme/mods?x=1",
        "acme/mods#frag",
    ] {
        let (status, _) = w
            .call(
                "POST",
                "/space/dock/sources",
                &w.admin,
                Some(json!({ "repo": bad })),
            )
            .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad:?} must be refused");
    }
    assert!(w.store.list_dock_sources().await.unwrap().is_empty());
}

#[tokio::test]
async fn sources_list_the_official_one_first_and_re_adding_is_idempotent() {
    let w = world("slimm-dock-sources-list").await;
    let id = w.add_source("acme/mods").await;
    let (status, again) = w
        .call(
            "POST",
            "/space/dock/sources",
            &w.admin,
            Some(json!({"repo": "ACME/mods"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(again["id"], json!(id));

    let (status, official) = w
        .call(
            "POST",
            "/space/dock/sources",
            &w.admin,
            Some(json!({"repo": "official/addons"})),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{official}");

    let (_, list) = w.call("GET", "/space/dock/sources", &w.admin, None).await;
    let list = list.as_array().unwrap();
    assert_eq!(list.len(), 2);
    assert_eq!(list[0]["id"], json!("official"));
    assert_eq!(list[0]["official"], json!(true));
    assert_eq!(list[1]["repo"], json!("acme/mods"));
}

#[tokio::test]
async fn a_broken_source_fails_alone_and_the_others_still_list() {
    let w = world("slimm-dock-sources-degrade").await;
    let bad = w.add_source("bad/repo").await;
    let good = w.add_source("acme/mods").await;
    let (status, _) = w
        .call(
            "GET",
            &format!("/space/dock/modules?source={bad}"),
            &w.admin,
            None,
        )
        .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    let (status, _) = w.call("GET", "/space/dock/modules", &w.admin, None).await;
    assert_eq!(status, StatusCode::OK);
    let (status, list) = w
        .call(
            "GET",
            &format!("/space/dock/modules?source={good}"),
            &w.admin,
            None,
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(list.as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn an_id_the_official_source_owns_is_shadowed_and_refused() {
    let w = world("slimm-dock-sources-collision-official").await;
    let acme = w.add_source("acme/mods").await;
    let (_, list) = w
        .call(
            "GET",
            &format!("/space/dock/modules?source={acme}"),
            &w.admin,
            None,
        )
        .await;
    let shadowed = |id: &str| {
        list.as_array()
            .unwrap()
            .iter()
            .find(|e| e["id"] == json!(id))
            .unwrap()["shadowed"]
            .clone()
    };
    assert_eq!(shadowed("code-exec"), json!(true));
    assert_eq!(shadowed("extra"), json!(false));

    let (status, body) = w.install(Some(&acme), "code-exec").await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert!(
        w.store
            .installed_module("code-exec")
            .await
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn an_id_installed_from_one_source_stays_with_it() {
    let w = world("slimm-dock-sources-collision-community").await;
    let acme = w.add_source("acme/mods").await;
    let zed = w.add_source("zed/mods").await;
    let (status, body) = w.install(Some(&acme), "extra").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["source_repo"], json!("acme/mods"));

    let (status, _) = w.install(Some(&zed), "extra").await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (_, list) = w
        .call(
            "GET",
            &format!("/space/dock/modules?source={zed}"),
            &w.admin,
            None,
        )
        .await;
    assert_eq!(list[0]["shadowed"], json!(true));

    let (status, _) = w.install(Some(&acme), "extra").await;
    assert_eq!(
        status,
        StatusCode::OK,
        "the same source may update its own module"
    );
}

#[tokio::test]
async fn official_installs_carry_no_source_label() {
    let w = world("slimm-dock-sources-official-label").await;
    let (status, body) = w.install(None, "code-exec").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(body.get("source_repo").is_none());
}

#[tokio::test]
async fn a_community_manifest_is_validated_like_the_official_one() {
    let w = world("slimm-dock-sources-validation").await;
    let acme = w.add_source("acme/mods").await;
    let (status, _) = w
        .call(
            "GET",
            &format!("/space/dock/modules/sneaky?source={acme}"),
            &w.admin,
            None,
        )
        .await;
    assert_eq!(
        status,
        StatusCode::BAD_GATEWAY,
        "a manifest whose id disagrees with its path"
    );
    let (status, _) = w.install(Some(&acme), "tampered").await;
    assert_eq!(
        status,
        StatusCode::BAD_GATEWAY,
        "an artifact that misses its pinned sha256"
    );
    assert!(
        w.store
            .installed_module("tampered")
            .await
            .unwrap()
            .is_none()
    );
    let (status, _) = w.install(Some("no-such-source"), "extra").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn removing_a_source_leaves_its_modules_installed_and_enabled() {
    let w = world("slimm-dock-sources-removal").await;
    let acme = w.add_source("acme/mods").await;
    let (status, _) = w.install(Some(&acme), "extra").await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = w
        .call("POST", "/space/dock/modules/extra/enable", &w.admin, None)
        .await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = w
        .call(
            "DELETE",
            &format!("/space/dock/sources/{acme}"),
            &w.admin,
            None,
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (_, installed) = w.call("GET", "/space/dock/installed", &w.admin, None).await;
    assert_eq!(installed[0]["id"], json!("extra"));
    assert_eq!(installed[0]["enabled"], json!(true));
    assert_eq!(installed[0]["source_repo"], json!("acme/mods"));

    let (status, _) = w.install(Some(&acme), "extra").await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "no updates until the source is added again"
    );
    let (status, _) = w
        .call(
            "DELETE",
            &format!("/space/dock/sources/{acme}"),
            &w.admin,
            None,
        )
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = w
        .call("DELETE", "/space/dock/sources/official", &w.admin, None)
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_source_with_no_registry_is_a_404_not_a_busy_server() {
    let w = world("slimm-dock-source-missing").await;
    let source = w.add_source("owner/nothing-here").await;
    let uri = format!("/space/dock/modules?source={source}");
    let (status, body) = w.call("GET", &uri, &w.admin, None).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    assert_eq!(body["error"], "no add-on registry was found at that source");
}
