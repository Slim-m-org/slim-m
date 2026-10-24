// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module's declared data through the Dock (decision 0091): created on
//! install when `data.store` is approved, grown on upgrade, never shrunk, kept
//! on uninstall unless the admin asks for it gone.

use std::sync::{Arc, Mutex};

use axum::Router;
use axum::body::Body;
use axum::extract::State;
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
use support::data_rig::{Rig, xp_schema};
use support::wasm_fixtures::{canned_ok_wasm, sha256_hex};
use support::{TestDbGuard, TestDirGuard};

fn manifest(version: &str, data: &Value, wasm: &[u8]) -> Value {
    manifest_with(version, data, wasm, (&["data.store"], &[]))
}

fn manifest_with(
    version: &str,
    data: &Value,
    wasm: &[u8],
    (capabilities, events): (&[&str], &[&str]),
) -> Value {
    let subscriptions: Vec<Value> = events.iter().map(|e| json!({ "event": e })).collect();
    json!({
        "schema": 1, "addon_api": 1, "id": "scores", "name": "Scores", "version": version,
        "summary": "keeps score",
        "artifact": {"kind": "wasm", "path": "modules/scores/module.wasm", "sha256": sha256_hex(wasm)},
        "runtime": {"backend": "wasm"},
        "permissions": [{"key": "run", "name": "Run", "description": "run"}],
        "capabilities": capabilities,
        "subscriptions": subscriptions,
        "data": data,
        "extension_points": [{"kind": "command", "name": "show", "description": "show", "permission": "run"}]
    })
}

#[derive(Clone)]
struct Served {
    manifest: Arc<Mutex<Value>>,
    wasm: Vec<u8>,
}

struct Harness {
    router: Router,
    token: String,
    served: Served,
    dir: std::path::PathBuf,
    _db: TestDbGuard,
    _dir: TestDirGuard,
}

async fn harness(name: &str) -> Harness {
    let (path, db_guard) = TestDbGuard::new(name);
    let (dir, dir_guard) = TestDirGuard::new("slimm-dockdata");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap()).with_modules_dir(dir.clone());
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
    let served = Served {
        manifest: Arc::new(Mutex::new(manifest("0.1.0", &xp_schema(), &wasm))),
        wasm,
    };
    let router = Router::new()
        .route(
            "/index.json",
            get(|| async {
                axum::Json(json!({"schema": 1, "modules": [
                    {"id": "scores", "name": "Scores", "version": "0.1.0", "summary": "keeps score"}]}))
            }),
        )
        .route(
            "/modules/scores/manifest.json",
            get(|State(s): State<Served>| async move { axum::Json(s.manifest.lock().unwrap().clone()) }),
        )
        .route(
            "/modules/scores/module.wasm",
            get(|State(s): State<Served>| async move { s.wasm.clone() }),
        )
        .with_state(served.clone());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}/", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let router = support::app::builder(store)
        .dock(Dock::for_test(&base))
        .router();
    Harness {
        router,
        token,
        served,
        dir,
        _db: db_guard,
        _dir: dir_guard,
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

    async fn install(&self, version: &str, approved: &[&str]) -> (StatusCode, Value) {
        self.call(
            "POST",
            "/space/dock/modules/scores/install",
            json!({"version": version, "approved_host_capabilities": approved}),
        )
        .await
    }

    fn serve_with(&self, version: &str, data: &Value, wants: (&[&str], &[&str])) {
        *self.served.manifest.lock().unwrap() =
            manifest_with(version, data, &self.served.wasm, wants);
    }

    /// Installs with no approvals named, so what the earlier install approved is carried.
    async fn reinstall_carrying(&self, version: &str) -> Vec<String> {
        let (status, body) = self
            .call(
                "POST",
                "/space/dock/modules/scores/install",
                json!({ "version": version }),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body["approved_host_capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c.as_str().unwrap().to_owned())
            .collect()
    }

    fn serve(&self, version: &str, data: &Value) {
        *self.served.manifest.lock().unwrap() = manifest(version, data, &self.served.wasm);
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn install_creates_the_declared_tables_only_when_data_store_is_approved() {
    let h = harness("slimm-dockdata-approve").await;
    let (status, _) = h.install("0.1.0", &[]).await;
    assert_eq!(status, StatusCode::OK);
    assert!(!h.dir.join("scores.db").exists(), "unapproved: no file");

    let (status, _) = h.install("0.1.0", &["data.store"]).await;
    assert_eq!(status, StatusCode::OK);
    let mut rig = Rig::attach(&h.dir, "scores", &["data.store"]);
    assert_eq!(
        rig.ok(json!({ "op": "count", "table": "xp" }))["count"],
        json!(0)
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn an_upgrade_grows_the_schema_and_a_shrinking_one_is_refused_before_it_installs() {
    let h = harness("slimm-dockdata-upgrade").await;
    h.install("0.1.0", &["data.store"]).await;
    let mut rig = Rig::attach(&h.dir, "scores", &["data.store"]);
    rig.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "u1", "points": 4 } }));

    let mut grown = xp_schema();
    grown["tables"][0]["columns"]
        .as_array_mut()
        .unwrap()
        .push(json!({ "name": "note", "type": "text" }));
    h.serve("0.2.0", &grown);
    let (status, body) = h.install("0.2.0", &["data.store"]).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    rig.renew();
    let row = rig.ok(json!({ "op": "get", "table": "xp" }));
    assert_eq!(row["rows"][0]["points"], json!(4));
    assert_eq!(row["rows"][0]["note"], Value::Null);

    h.serve("0.3.0", &xp_schema());
    let (status, body) = h.install("0.3.0", &["data.store"]).await;
    assert_eq!(status, StatusCode::BAD_GATEWAY, "{body}");
    assert!(
        body["error"].as_str().unwrap().contains("may only grow"),
        "{body}"
    );
    let (_, installed) = h.call("GET", "/space/dock/installed", Value::Null).await;
    assert_eq!(
        installed[0]["version"],
        json!("0.2.0"),
        "the refused upgrade did not install"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_manifest_with_an_invalid_schema_or_a_changed_one_is_not_the_one_reviewed() {
    let h = harness("slimm-dockdata-review").await;
    let (_, shown) = h
        .call("GET", "/space/dock/modules/scores", Value::Null)
        .await;
    let reviewed = shown["review_digest"].as_str().unwrap().to_owned();
    let mut bigger = xp_schema();
    bigger["max_mb"] = json!(64);
    h.serve("0.1.0", &bigger);
    let (status, _) = h
        .call("POST", "/space/dock/modules/scores/install",
            json!({"version": "0.1.0", "approved_host_capabilities": ["data.store"], "reviewed_digest": reviewed}))
        .await;
    assert_eq!(status, StatusCode::CONFLICT);

    let mut invalid = xp_schema();
    invalid["tables"][0]["name"] = json!("drop table");
    h.serve("0.1.0", &invalid);
    let (status, _) = h.install("0.1.0", &["data.store"]).await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert!(!h.dir.join("scores.db").exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn uninstall_keeps_the_data_file_unless_asked_to_delete_it() {
    let h = harness("slimm-dockdata-uninstall").await;
    h.install("0.1.0", &["data.store"]).await;
    let mut rig = Rig::attach(&h.dir, "scores", &["data.store"]);
    rig.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "u1", "points": 4 } }));

    let (status, _) = h
        .call("DELETE", "/space/dock/modules/scores/install", Value::Null)
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(h.dir.join("scores.db").exists(), "kept by default");

    // A reinstall finds the data where it was left.
    h.install("0.1.0", &["data.store"]).await;
    rig.renew();
    assert_eq!(
        rig.ok(json!({ "op": "count", "table": "xp" }))["count"],
        json!(1)
    );

    let (status, _) = h
        .call(
            "DELETE",
            "/space/dock/modules/scores/install?delete_data=true",
            Value::Null,
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let leftovers: Vec<_> = std::fs::read_dir(&h.dir).unwrap().flatten().collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
}

const BOTH: (&[&str], &[&str]) = (&["data.store", "events"], &["message.created"]);

#[tokio::test(flavor = "multi_thread")]
async fn an_unchanged_manifest_carries_events_and_data_store() {
    let h = harness("slimm-dockdata-carry").await;
    h.serve_with("0.1.0", &xp_schema(), BOTH);
    h.install("0.1.0", &["data.store", "events"]).await;
    h.serve_with("0.1.1", &xp_schema(), BOTH);
    let mut carried = h.reinstall_carrying("0.1.1").await;
    carried.sort();
    assert_eq!(carried, ["data.store", "events"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_subscription_with_the_same_artifact_asks_for_events_again() {
    let h = harness("slimm-dockdata-subs").await;
    h.serve_with("0.1.0", &xp_schema(), BOTH);
    h.install("0.1.0", &["data.store", "events"]).await;
    let wider = (
        &["data.store", "events"][..],
        &["message.created", "member.joined"][..],
    );
    h.serve_with("0.1.1", &xp_schema(), wider);
    assert_eq!(h.reinstall_carrying("0.1.1").await, ["data.store"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_larger_cap_or_a_new_table_with_the_same_artifact_asks_for_data_store_again() {
    let h = harness("slimm-dockdata-wider").await;
    h.serve_with("0.1.0", &xp_schema(), BOTH);
    h.install("0.1.0", &["data.store", "events"]).await;

    let mut bigger = xp_schema();
    bigger["max_mb"] = json!(16);
    h.serve_with("0.1.1", &bigger, BOTH);
    assert_eq!(h.reinstall_carrying("0.1.1").await, ["events"]);

    h.install("0.1.1", &["data.store", "events"]).await;
    let mut more = bigger.clone();
    more["tables"]
        .as_array_mut()
        .unwrap()
        .push(json!({ "name": "log", "columns": [{ "name": "line", "type": "text" }] }));
    h.serve_with("0.1.2", &more, BOTH);
    assert_eq!(h.reinstall_carrying("0.1.2").await, ["events"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn making_a_column_unique_over_repeated_values_is_refused_before_it_installs() {
    let h = harness("slimm-dockdata-dupes").await;
    let loose = json!({ "max_mb": 8, "tables": [{ "name": "xp", "columns": [
        { "name": "user_id", "type": "text" }] }] });
    h.serve("0.1.0", &loose);
    h.install("0.1.0", &["data.store"]).await;
    let mut rig = Rig::attach(&h.dir, "scores", &["data.store"]);
    for _ in 0..2 {
        rig.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "same" } }));
    }
    rig.ok(json!({ "op": "insert", "table": "xp", "values": {} }));
    rig.ok(json!({ "op": "insert", "table": "xp", "values": {} }));

    let strict = json!({ "max_mb": 8, "tables": [{ "name": "xp", "columns": [
        { "name": "user_id", "type": "text", "unique": true }] }] });
    h.serve("0.2.0", &strict);
    let (status, body) = h.install("0.2.0", &["data.store"]).await;
    assert_eq!(status, StatusCode::BAD_GATEWAY, "{body}");
    assert!(
        body["error"]
            .as_str()
            .unwrap()
            .contains("cannot become unique"),
        "{body}"
    );
    let (_, installed) = h.call("GET", "/space/dock/installed", Value::Null).await;
    assert_eq!(
        installed[0]["version"],
        json!("0.1.0"),
        "the old build stays installed"
    );

    rig.renew();
    let rows = rig.ok(json!({ "op": "count", "table": "xp" }));
    assert_eq!(rows["count"], json!(4));
}

#[tokio::test(flavor = "multi_thread")]
async fn making_a_column_unique_over_distinct_values_installs() {
    let h = harness("slimm-dockdata-distinct").await;
    let loose = json!({ "max_mb": 8, "tables": [{ "name": "xp", "columns": [
        { "name": "user_id", "type": "text" }] }] });
    h.serve("0.1.0", &loose);
    h.install("0.1.0", &["data.store"]).await;
    let mut rig = Rig::attach(&h.dir, "scores", &["data.store"]);
    rig.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "a" } }));
    rig.ok(json!({ "op": "insert", "table": "xp", "values": {} }));
    rig.ok(json!({ "op": "insert", "table": "xp", "values": {} }));
    let strict = json!({ "max_mb": 8, "tables": [{ "name": "xp", "columns": [
        { "name": "user_id", "type": "text", "unique": true }] }] });
    h.serve("0.2.0", &strict);
    let (status, body) = h.install("0.2.0", &["data.store"]).await;
    assert_eq!(status, StatusCode::OK, "{body}");
}
