// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `data.store` additive ops (decision 0091): `upsert` and `update` with `add`,
//! and multi-row `insert`.

use serde_json::{Value, json};

mod support;
use support::TestDirGuard;
use support::data_rig::{Rig, xp_schema};

async fn rig(prefix: &str) -> (Rig, TestDirGuard) {
    let (dir, guard) = TestDirGuard::new(prefix);
    (Rig::new(&dir, "game", xp_schema()).await, guard)
}

fn bump(user: &str, by: i64) -> Value {
    json!({ "op": "upsert", "table": "xp", "on": "user_id",
        "values": { "user_id": user }, "add": { "points": by } })
}

fn points(r: &mut Rig, user: &str) -> Value {
    let got = r.ok(json!({ "op": "get", "table": "xp",
        "where": [{ "col": "user_id", "op": "eq", "val": user }] }));
    got["rows"][0]["points"].clone()
}

fn count(r: &mut Rig) -> Value {
    r.ok(json!({ "op": "count", "table": "xp" }))["count"].clone()
}

#[tokio::test(flavor = "multi_thread")]
async fn upsert_add_creates_then_accumulates_and_returns_the_row() {
    let (mut r, _g) = rig("slimm-add-upsert").await;
    let first = r.ok(bump("ann", 5));
    assert_eq!(first["rows"][0]["user_id"], json!("ann"));
    assert_eq!(first["rows"][0]["points"], json!(5));
    assert_eq!(first["changed"], json!(1));
    let second = r.ok(json!({ "op": "upsert", "table": "xp", "on": "user_id",
        "values": { "user_id": "ann", "active": true }, "add": { "points": 7, "ratio": 0.5 } }));
    let row = &second["rows"][0];
    assert_eq!((&row["points"], &row["ratio"]), (&json!(12), &json!(0.5)));
    assert_eq!(row["active"], json!(true));
    assert_eq!(row["_id"], first["rows"][0]["_id"]);
    assert_eq!(count(&mut r), json!(1));
    assert_eq!(r.ok(bump("ann", -2))["rows"][0]["points"], json!(10));
}

#[tokio::test(flavor = "multi_thread")]
async fn concurrent_upsert_adds_from_two_connections_lose_nothing() {
    let (r, guard) = rig("slimm-add-race").await;
    let dir = r.dir.clone();
    let mut tasks = Vec::new();
    for _ in 0..2 {
        let dir = dir.clone();
        tasks.push(tokio::spawn(async move {
            let mut mine = Rig::attach(&dir, "game", &["data.store"]);
            let mut added = 0;
            for _ in 0..30 {
                let reply = mine.store(bump("shared", 1));
                if reply["ok"] == json!(true) {
                    added += 1;
                } else {
                    // A busy refusal under heavy load is allowed; an add that reports success and is lost is not.
                    assert_eq!(
                        reply["error"],
                        json!("data.store is unavailable"),
                        "{reply}"
                    );
                }
            }
            added
        }));
    }
    let mut added = 0;
    for task in tasks {
        added += task.await.unwrap();
    }
    assert!(added > 0, "every add was refused");
    let mut r = r;
    r.renew();
    assert_eq!(points(&mut r, "shared"), json!(added));
    drop(guard);
}

#[tokio::test(flavor = "multi_thread")]
async fn insert_rows_returns_ids_and_is_all_or_nothing() {
    let (mut r, _g) = rig("slimm-add-rows").await;
    let done = r.ok(json!({ "op": "insert", "table": "xp", "rows": [
        { "user_id": "a", "points": 1 }, { "user_id": "b", "points": 2 },
        { "user_id": "c", "points": 3 }] }));
    assert_eq!(
        done["rows"],
        json!([{ "_id": 1 }, { "_id": 2 }, { "_id": 3 }])
    );
    assert_eq!(done["changed"], json!(3));
    // The last row repeats a unique value, so the earlier new row must not stay.
    let bad = r.refused(json!({ "op": "insert", "table": "xp", "rows": [
        { "user_id": "d", "points": 4 }, { "user_id": "a", "points": 9 }] }));
    assert!(bad.contains("unique"), "{bad}");
    assert_eq!(count(&mut r), json!(3));
    // A row that fails validation writes none either.
    r.refused(json!({ "op": "insert", "table": "xp", "rows": [
        { "user_id": "e", "points": 1 }, { "user_id": "f", "points": "many" }] }));
    assert_eq!(count(&mut r), json!(3));
}

#[tokio::test(flavor = "multi_thread")]
async fn update_add_is_atomic_and_works_with_or_without_values() {
    let (mut r, _g) = rig("slimm-add-update").await;
    r.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "u", "points": 10 } }));
    let by_id = json!([{ "col": "user_id", "op": "eq", "val": "u" }]);
    let only =
        r.ok(json!({ "op": "update", "table": "xp", "add": { "points": 5 }, "where": by_id }));
    assert_eq!(only["changed"], json!(1));
    assert_eq!(points(&mut r, "u"), json!(15));
    r.ok(
        json!({ "op": "update", "table": "xp", "values": { "active": true },
        "add": { "points": -20, "ratio": 1.5 }, "where": by_id }),
    );
    let row = r.ok(json!({ "op": "get", "table": "xp" }))["rows"][0].clone();
    assert_eq!(row["points"], json!(-5));
    assert_eq!(row["ratio"], json!(1.5));
    assert_eq!(row["active"], json!(true));
    // A null column starts from zero.
    r.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "n" } }));
    r.ok(
        json!({ "op": "update", "table": "xp", "add": { "points": 3 },
        "where": [{ "col": "user_id", "op": "eq", "val": "n" }] }),
    );
    assert_eq!(points(&mut r, "n"), json!(3));
}

#[tokio::test(flavor = "multi_thread")]
async fn invalid_additive_requests_are_refused_and_write_nothing() {
    let (mut r, _g) = rig("slimm-add-bad").await;
    r.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "keep", "points": 1 } }));
    let many: Vec<Value> = (0..51)
        .map(|i| json!({ "user_id": format!("m{i}") }))
        .collect();
    let on = json!({ "op": "upsert", "table": "xp", "on": "user_id" });
    let with = |extra: Value| {
        let mut req = on.clone();
        for (k, v) in extra.as_object().unwrap() {
            req[k] = v.clone();
        }
        req
    };
    for request in [
        json!({ "op": "insert", "table": "xp", "rows": [] }),
        json!({ "op": "insert", "table": "xp", "rows": many }),
        json!({ "op": "insert", "table": "xp", "rows": [{}] }),
        json!({ "op": "insert", "table": "xp", "rows": [{ "user_id": "a" }, { "points": 1 }] }),
        json!({ "op": "insert", "table": "xp", "rows": [{ "_id": 5 }] }),
        json!({ "op": "insert", "table": "xp", "values": { "user_id": "a" }, "rows": [{ "user_id": "b" }] }),
        json!({ "op": "insert", "table": "xp", "values": { "user_id": "a" }, "add": { "points": 1 } }),
        json!({ "op": "update", "table": "xp", "rows": [{ "points": 1 }], "add": { "points": 1 } }),
        json!({ "op": "update", "table": "xp", "add": {} }),
        json!({ "op": "update", "table": "xp", "add": { "user_id": 1 } }),
        json!({ "op": "update", "table": "xp", "add": { "active": 1 } }),
        json!({ "op": "update", "table": "xp", "add": { "user_id": "x" } }),
        json!({ "op": "update", "table": "xp", "add": { "active": true } }),
        json!({ "op": "update", "table": "xp", "add": { "nope": 1 } }),
        json!({ "op": "update", "table": "xp", "add": { "_id": 1 } }),
        json!({ "op": "update", "table": "xp", "add": { "points": "1" } }),
        json!({ "op": "update", "table": "xp", "add": { "points": null } }),
        json!({ "op": "update", "table": "xp", "add": { "points": 1.5 } }),
        json!({ "op": "update", "table": "xp", "add": { "points": 9_007_199_254_740_993_i64 } }),
        json!({ "op": "update", "table": "xp", "values": { "points": 1 }, "add": { "points": 1 } }),
        json!({ "op": "delete", "table": "xp", "add": { "points": 1 } }),
        with(json!({ "values": { "user_id": "a" }, "add": { "user_id": 1 } })),
        with(json!({ "values": { "user_id": "a" }, "add": { "ghost": 1 } })),
        with(json!({ "values": { "user_id": "a" }, "add": { "active": 1 } })),
        with(json!({ "values": { "user_id": "a", "points": 1 }, "add": { "points": 1 } })),
        with(json!({ "values": { "points": 1 }, "add": { "points": 1 } })),
        with(json!({ "values": { "user_id": "a" }, "rows": [{ "user_id": "b" }] })),
    ] {
        let reply = r.store(request.clone());
        assert_eq!(reply["ok"], json!(false), "{request} -> {reply}");
    }
    assert_eq!(count(&mut r), json!(1));
    assert_eq!(points(&mut r, "keep"), json!(1));
}

#[tokio::test(flavor = "multi_thread")]
async fn hostile_add_keys_and_row_keys_never_reach_sql() {
    let (mut r, _g) = rig("slimm-add-inject").await;
    r.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "victim", "points": 1 } }));
    let evil = "points\"=0; DROP TABLE xp; --";
    for request in [
        json!({ "op": "update", "table": "xp", "add": { evil: 1 } }),
        json!({ "op": "upsert", "table": "xp", "on": "user_id",
            "values": { "user_id": "x" }, "add": { evil: 1 } }),
        json!({ "op": "insert", "table": "xp", "rows": [{ evil: 1 }] }),
        json!({ "op": "insert", "table": "xp", "rows": [{ "user_id": evil }, { evil: 1 }] }),
    ] {
        let reply = r.store(request.clone());
        assert_eq!(reply["ok"], json!(false), "{request} -> {reply}");
    }
    // As row values the same text is plain data.
    r.ok(json!({ "op": "insert", "table": "xp", "rows": [{ "user_id": evil }] }));
    assert_eq!(points(&mut r, "victim"), json!(1));
    assert_eq!(count(&mut r), json!(2));
}

#[tokio::test(flavor = "multi_thread")]
async fn each_additive_call_spends_one_of_the_run_budget() {
    let (mut r, _g) = rig("slimm-add-budget").await;
    let rows: Vec<Value> = (0..50)
        .map(|i| json!({ "user_id": format!("b{i}") }))
        .collect();
    r.ok(json!({ "op": "insert", "table": "xp", "rows": rows }));
    for _ in 0..62 {
        r.ok(bump("one", 1));
    }
    r.ok(json!({ "op": "update", "table": "xp", "add": { "points": 1 } }));
    let over = r.refused(bump("one", 1));
    assert!(over.contains("budget"), "{over}");
    r.renew();
    assert_eq!(points(&mut r, "one"), json!(62 + 1));
    assert_eq!(count(&mut r), json!(51));
}

#[tokio::test(flavor = "multi_thread")]
async fn old_style_writes_behave_as_before() {
    let (mut r, _g) = rig("slimm-add-compat").await;
    let ins =
        r.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "a", "points": 1 } }));
    assert_eq!(
        (&ins["rows"], &ins["changed"]),
        (&json!([{ "_id": 1 }]), &json!(1))
    );
    let up = r.ok(json!({ "op": "upsert", "table": "xp", "on": "user_id",
        "values": { "user_id": "a", "points": 7 } }));
    assert_eq!((&up["rows"], &up["changed"]), (&json!([]), &json!(1)));
    assert_eq!(points(&mut r, "a"), json!(7));
    let upd = r.ok(json!({ "op": "update", "table": "xp", "values": { "points": 2 } }));
    assert_eq!(upd["changed"], json!(1));
    assert_eq!(points(&mut r, "a"), json!(2));
    r.ok(json!({ "op": "insert", "table": "xp", "values": {} }));
    assert_eq!(count(&mut r), json!(2));
}
