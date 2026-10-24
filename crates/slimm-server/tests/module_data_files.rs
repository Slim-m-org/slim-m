// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The module data file itself (decision 0091): one private file per module,
//! its cap, additive migration, the run's shared call budget and the approval
//! gate, plus one run through a real wasm module.

use serde_json::{Value, json};
use slimm_server::module_runtime::{valid_file_id, validate_data_schema};

mod support;
use support::TestDirGuard;
use support::data_rig::{Rig, files, xp_schema};
use support::module_world::{Install, world};
use support::wasm_fixtures::host_call_loop_wasm;

fn blob_schema(max_mb: u32) -> Value {
    json!({ "max_mb": max_mb, "tables": [{ "name": "blob",
        "columns": [{ "name": "body", "type": "text" }] }] })
}

#[tokio::test(flavor = "multi_thread")]
async fn a_module_id_that_is_not_a_plain_name_never_reaches_the_disk() {
    let (dir, _g) = TestDirGuard::new("slimm-data-ids");
    let schema = validate_data_schema(&xp_schema()).unwrap();
    for id in [
        "../x",
        "a/b",
        "..",
        ".",
        "a\\b",
        "",
        "UP",
        "x.db",
        "-x",
        &"a".repeat(65),
    ] {
        assert!(!valid_file_id(id), "{id:?}");
        assert!(
            files(&dir).apply_schema(id, &schema).await.is_err(),
            "{id:?}"
        );
        assert!(
            files(&dir).check_schema(id, &schema).await.is_err(),
            "{id:?}"
        );
        assert!(files(&dir).delete_data(id).await.is_err(), "{id:?}");
        let mut rig = Rig::attach(&dir, id, &["data.store"]);
        let error = rig.refused(json!({ "op": "query", "table": "xp" }));
        assert!(error.contains("declared no data"), "{id:?}: {error}");
    }
    assert!(!dir.parent().unwrap().join("x.db").exists());
    let entries = std::fs::read_dir(&dir).map(Iterator::count).unwrap_or(0);
    assert_eq!(entries, 0, "nothing was created for a refused id");
}

#[tokio::test(flavor = "multi_thread")]
async fn modules_cannot_see_each_others_rows_and_files_are_private() {
    let (dir, _g) = TestDirGuard::new("slimm-data-split");
    let mut a = Rig::new(&dir, "alpha", xp_schema()).await;
    let mut b = Rig::new(&dir, "beta", xp_schema()).await;
    a.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "only-in-alpha" } }));
    assert_eq!(
        b.ok(json!({ "op": "count", "table": "xp" }))["count"],
        json!(0)
    );
    assert!(dir.join("alpha.db").exists() && dir.join("beta.db").exists());
    // The only way to name a table is the module's own schema, so the host's tables are out of reach.
    assert!(
        !b.refused(json!({ "op": "query", "table": "_slim_meta" }))
            .is_empty()
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&dir), 0o700);
        assert_eq!(mode(&dir.join("alpha.db")), 0o600);
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_full_file_returns_a_clean_error_and_recovers_when_rows_go() {
    let (dir, _g) = TestDirGuard::new("slimm-data-cap");
    let mut rig = Rig::new(&dir, "capped", blob_schema(1)).await;
    let big = "x".repeat(4096);
    let mut stored = 0;
    let mut error = String::new();
    'fill: for _ in 0..10 {
        rig.renew();
        for _ in 0..50 {
            let reply =
                rig.store(json!({ "op": "insert", "table": "blob", "values": { "body": big } }));
            if reply["ok"] == json!(false) {
                error = reply["error"].as_str().unwrap().to_owned();
                break 'fill;
            }
            stored += 1;
        }
    }
    assert!(
        error.contains("full"),
        "never filled: {stored} rows, {error:?}"
    );
    assert!((100..=300).contains(&stored), "{stored}");
    rig.renew();
    assert_eq!(
        rig.ok(json!({ "op": "count", "table": "blob" }))["count"],
        json!(stored)
    );
    rig.ok(json!({ "op": "delete", "table": "blob",
        "where": [{ "col": "_id", "op": "lte", "val": 20 }] }));
    rig.ok(json!({ "op": "insert", "table": "blob", "values": { "body": "fits again" } }));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_schema_may_only_grow() {
    let (dir, _g) = TestDirGuard::new("slimm-data-migrate");
    let mut rig = Rig::new(&dir, "grower", xp_schema()).await;
    rig.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "u1", "points": 3 } }));

    let mut grown = xp_schema();
    grown["tables"][0]["columns"]
        .as_array_mut()
        .unwrap()
        .push(json!({ "name": "title", "type": "text", "index": true }));
    grown["tables"]
        .as_array_mut()
        .unwrap()
        .push(json!({ "name": "log",
        "columns": [{ "name": "line", "type": "text" }] }));
    let parsed = validate_data_schema(&grown).unwrap();
    files(&dir).apply_schema("grower", &parsed).await.unwrap();
    files(&dir).apply_schema("grower", &parsed).await.unwrap();

    let mut rig = Rig::attach(&dir, "grower", &["data.store"]);
    let row = rig.ok(json!({ "op": "get", "table": "xp" }));
    assert_eq!(row["rows"][0]["points"], json!(3));
    assert_eq!(row["rows"][0]["title"], Value::Null);
    rig.ok(json!({ "op": "update", "table": "xp", "values": { "title": "champ" } }));
    rig.ok(json!({ "op": "insert", "table": "log", "values": { "line": "hello" } }));

    let mut removed_column = grown.clone();
    removed_column["tables"][0]["columns"]
        .as_array_mut()
        .unwrap()
        .pop();
    let mut retyped = grown.clone();
    retyped["tables"][0]["columns"][1]["type"] = json!("text");
    let mut removed_table = grown.clone();
    removed_table["tables"].as_array_mut().unwrap().pop();
    for (what, schema) in [
        ("column", removed_column),
        ("type", retyped),
        ("table", removed_table),
    ] {
        let parsed = validate_data_schema(&schema).unwrap();
        let error = files(&dir)
            .apply_schema("grower", &parsed)
            .await
            .unwrap_err();
        assert!(error.contains("may only grow"), "{what}: {error}");
        assert!(files(&dir).check_schema("grower", &parsed).await.is_err());
    }
    rig.renew();
    assert_eq!(
        rig.ok(json!({ "op": "count", "table": "log" }))["count"],
        json!(1)
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_unique_column_over_duplicate_rows_is_refused_and_leaves_the_file_alone() {
    let (dir, _g) = TestDirGuard::new("slimm-data-unique-late");
    let mut rig = Rig::new(&dir, "dupes", blob_schema(1)).await;
    for _ in 0..2 {
        rig.ok(json!({ "op": "insert", "table": "blob", "values": { "body": "same" } }));
    }
    let mut schema = blob_schema(1);
    schema["tables"][0]["columns"][0]["unique"] = json!(true);
    let parsed = validate_data_schema(&schema).unwrap();
    assert!(files(&dir).apply_schema("dupes", &parsed).await.is_err());
    rig.renew();
    rig.ok(json!({ "op": "insert", "table": "blob", "values": { "body": "same" } }));
}

#[tokio::test(flavor = "multi_thread")]
async fn data_calls_share_the_run_budget_with_kv() {
    let (dir, _g) = TestDirGuard::new("slimm-data-budget");
    let mut rig = Rig::new(&dir, "busy", xp_schema()).await;
    for i in 0..32 {
        rig.raw(
            &json!({ "capability": "kv.store", "op": "set", "key": format!("k{i}"), "value": "v" }),
        );
    }
    for _ in 0..32 {
        rig.ok(json!({ "op": "count", "table": "xp" }));
    }
    assert!(
        rig.refused(json!({ "op": "count", "table": "xp" }))
            .contains("budget")
    );
    let kv = rig.raw(&json!({ "capability": "kv.store", "op": "list" }));
    assert_eq!(kv["ok"], json!(false));
    rig.renew();
    rig.ok(json!({ "op": "count", "table": "xp" }));
}

#[tokio::test(flavor = "multi_thread")]
async fn data_store_needs_approval_a_backend_and_a_declared_schema() {
    let (dir, _g) = TestDirGuard::new("slimm-data-gate");
    Rig::new(&dir, "gated", xp_schema()).await;

    let mut kv_only = Rig::attach(&dir, "gated", &["kv.store"]);
    let error = kv_only.refused(json!({ "op": "count", "table": "xp" }));
    assert!(error.contains("not approved: data.store"), "{error}");

    let mut undeclared = Rig::attach(&dir, "never-declared", &["data.store"]);
    let error = undeclared.refused(json!({ "op": "count", "table": "xp" }));
    assert!(error.contains("declared no data"), "{error}");
    assert!(
        !dir.join("never-declared.db").exists(),
        "a read must not create a file"
    );
}

#[tokio::test]
async fn a_wasm_module_stores_and_reads_back_through_the_run_route() {
    let w = world("slimm-data-wasm").await;
    let schema = validate_data_schema(&xp_schema()).unwrap();
    files(&w.modules_dir)
        .apply_schema("scores", &schema)
        .await
        .unwrap();
    let write = json!({ "capability": "data.store", "op": "insert", "table": "xp",
        "values": { "user_id": "nia", "points": 7 } });
    w.install(Install {
        id: "scores",
        wasm: host_call_loop_wasm(&write.to_string(), 1),
        declared: &["data.store"],
        approved_host: &["data.store"],
    })
    .await;
    let answer = w.answer("scores").await;
    assert!(answer.contains("'ok':true"), "{answer}");

    let read = json!({ "capability": "data.store", "op": "get", "table": "xp" });
    w.install(Install {
        id: "scores",
        wasm: host_call_loop_wasm(&read.to_string(), 1),
        declared: &["data.store"],
        approved_host: &["data.store"],
    })
    .await;
    let answer = w.answer("scores").await;
    assert!(
        answer.contains("'user_id':'nia'") && answer.contains("'points':7"),
        "{answer}"
    );

    w.install(Install {
        id: "scores",
        wasm: host_call_loop_wasm(&read.to_string(), 1),
        declared: &["data.store"],
        approved_host: &[],
    })
    .await;
    assert!(w.answer("scores").await.contains("declares an import"));
}

#[tokio::test(flavor = "multi_thread")]
async fn the_dock_hands_every_caller_one_data_store() {
    let (dir, _g) = TestDirGuard::new("slimm-data-shared");
    let dock = slimm_server::http::dock::Dock::disabled();
    let first = dock.module_data(dir.clone());
    let second = dock.clone().module_data(dir);
    assert!(std::sync::Arc::ptr_eq(&first, &second));
}

#[tokio::test(flavor = "multi_thread")]
async fn deleting_a_modules_data_closes_the_pool_a_run_opened() {
    use slimm_server::module_runtime::DataBackend;
    let (dir, _g) = TestDirGuard::new("slimm-data-delete-open");
    let schema = validate_data_schema(&xp_schema()).unwrap();
    let data = files(&dir);
    data.apply_schema("scores", &schema).await.unwrap();
    let probe = || {
        let data = &data;
        tokio::task::block_in_place(|| data.schema("scores").is_ok())
    };
    assert!(probe());
    data.delete_data("scores").await.unwrap();
    assert!(
        !probe(),
        "a deleted module must not be served from a cached pool"
    );
    assert!(!dir.join("scores.db").exists());
}
