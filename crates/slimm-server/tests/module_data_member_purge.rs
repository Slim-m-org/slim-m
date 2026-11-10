// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting an account purges the rows a module's data store holds about that
//! member, for every column the manifest marks `member`, and nobody else's.

use axum::http::StatusCode;
use std::time::Duration;

use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http;
use slimm_server::module_runtime::{
    DataBackend, DataError, DataSchema, Outcome, SqliteData, Statement, purge_member,
    validate_data_schema,
};
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;
use support::app::{request_bearer as request, request_json};
use support::data_rig::{Rig, files};
use support::{TestDbGuard, TestDirGuard};

fn schema() -> Value {
    json!({ "max_mb": 8, "tables": [
        { "name": "xp", "columns": [
            { "name": "user_id", "type": "text", "member": true },
            { "name": "points", "type": "int" }] },
        { "name": "duel", "columns": [
            { "name": "winner", "type": "text", "member": true },
            { "name": "loser", "type": "text", "member": true },
            { "name": "note", "type": "text" }] }] })
}

#[test]
fn a_member_column_must_be_text() {
    let bad = json!({ "tables": [{ "name": "t", "columns": [
        { "name": "who", "type": "int", "member": true }] }] });
    let err = validate_data_schema(&bad).unwrap_err();
    assert!(err.contains("must be text"), "{err}");
}

#[tokio::test(flavor = "multi_thread")]
async fn deleting_an_account_removes_its_rows_from_module_data_and_keeps_the_rest() {
    let (path, _db) = TestDbGuard::new("slimm-member-purge");
    let (dir, _dir) = TestDirGuard::new("slimm-member-purge-files");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap()).with_modules_dir(dir.clone());
    let admin = store.create_account("root", "Root", "x").await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let token = store
        .open_session(admin.id, "cli")
        .await
        .unwrap()
        .access_token;
    let gone = store.create_account("gone", "Gone", "x").await.unwrap();
    let kept = store.create_account("kept", "Kept", "x").await.unwrap();
    let (gone, kept) = (gone.id.to_string(), kept.id.to_string());

    files(&dir)
        .apply_schema("scores", &validate_data_schema(&schema()).unwrap())
        .await
        .unwrap();
    let mut rig = Rig::attach(&dir, "scores", &["data.store"]);
    let rows = [
        ("xp", json!({ "user_id": gone, "points": 5 })),
        ("xp", json!({ "user_id": kept, "points": 7 })),
        (
            "duel",
            json!({ "winner": gone, "loser": kept, "note": "a" }),
        ),
        (
            "duel",
            json!({ "winner": kept, "loser": gone, "note": "b" }),
        ),
        (
            "duel",
            json!({ "winner": kept, "loser": kept, "note": "c" }),
        ),
    ];
    for (table, values) in rows {
        rig.ok(json!({ "op": "insert", "table": table, "values": values }));
    }

    let app = http::router(support::app::state(store));
    let response = app
        .oneshot(request(
            "DELETE",
            &format!("/members/{gone}/account"),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    rig.renew();
    let xp = rig.ok(json!({ "op": "query", "table": "xp" }));
    assert_eq!(xp["rows"].as_array().unwrap().len(), 1);
    assert_eq!(xp["rows"][0]["user_id"], json!(kept));
    let duel = rig.ok(json!({ "op": "query", "table": "duel" }));
    let notes: Vec<&str> = duel["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["note"].as_str().unwrap())
        .collect();
    assert_eq!(
        notes,
        ["c"],
        "either column naming the member removes the row"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_removed_member_who_can_come_back_keeps_their_module_rows() {
    let (path, _db) = TestDbGuard::new("slimm-member-purge-removal");
    let (dir, _dir) = TestDirGuard::new("slimm-member-purge-removal-files");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap()).with_modules_dir(dir.clone());
    let admin = store.create_account("root", "Root", "x").await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let token = store
        .open_session(admin.id, "cli")
        .await
        .unwrap()
        .access_token;
    let away = store.create_account("away", "Away", "x").await.unwrap().id;

    files(&dir)
        .apply_schema("scores", &validate_data_schema(&schema()).unwrap())
        .await
        .unwrap();
    let mut rig = Rig::attach(&dir, "scores", &["data.store"]);
    rig.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": away.to_string(), "points": 1 } }));

    let app = http::router(support::app::state(store));
    let response = app
        .oneshot(request_json(
            "PUT",
            &format!("/members/{away}/removal"),
            &token,
            json!({}),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    rig.renew();
    assert_eq!(
        rig.ok(json!({ "op": "count", "table": "xp" }))["count"],
        json!(1)
    );
}

/// Runs for real, except that any statement touching `failing` is refused.
struct FailsOn {
    inner: SqliteData,
    failing: &'static str,
}

impl DataBackend for FailsOn {
    fn schema(&self, module_id: &str) -> Result<DataSchema, DataError> {
        self.inner.schema(module_id)
    }

    fn execute(
        &self,
        module_id: &str,
        statement: &Statement,
        budget: Duration,
    ) -> Result<Outcome, DataError> {
        if statement.sql.contains(self.failing) {
            return Err(DataError::Unavailable);
        }
        self.inner.execute(module_id, statement, budget)
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn one_failing_table_does_not_stop_the_purge_of_the_rest() {
    let (dir, _dir) = TestDirGuard::new("slimm-member-purge-partial");
    files(&dir)
        .apply_schema("scores", &validate_data_schema(&schema()).unwrap())
        .await
        .unwrap();
    let mut rig = Rig::attach(&dir, "scores", &["data.store"]);
    for table in ["xp", "duel"] {
        let column = if table == "xp" { "user_id" } else { "winner" };
        rig.ok(json!({ "op": "insert", "table": table, "values": { column: "gone" } }));
    }
    let backend = FailsOn {
        inner: files(&dir),
        failing: "\"xp\"",
    };

    let outcome = tokio::task::block_in_place(|| purge_member(&backend, "scores", "gone"));

    assert!(
        matches!(outcome, Err(DataError::Unavailable)),
        "{outcome:?}"
    );
    rig.renew();
    let duel = rig.ok(json!({ "op": "count", "table": "duel" }));
    assert_eq!(duel["count"], json!(0), "the table after the failing one");
    let xp = rig.ok(json!({ "op": "count", "table": "xp" }));
    assert_eq!(xp["count"], json!(1), "the failing table keeps its row");
}
