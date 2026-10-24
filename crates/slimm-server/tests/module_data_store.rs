// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `data.store` (decision 0091): every operation and where operator, an
//! XP-style leaderboard, and hostile input through every field the host
//! builds SQL from.

use serde_json::{Value, json};

mod support;
use support::TestDirGuard;
use support::data_rig::{Rig, xp_schema};

async fn rig(prefix: &str) -> (Rig, TestDirGuard) {
    let (dir, guard) = TestDirGuard::new(prefix);
    (Rig::new(&dir, "game", xp_schema()).await, guard)
}

fn names(reply: &Value) -> Vec<String> {
    reply["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["user_id"].as_str().unwrap().to_owned())
        .collect()
}

fn add(rig: &mut Rig, user: &str, points: i64) {
    rig.ok(json!({ "op": "insert", "table": "xp",
        "values": { "user_id": user, "points": points, "ratio": 0.5, "active": true } }));
}

#[tokio::test(flavor = "multi_thread")]
async fn insert_get_update_delete_and_count_round_trip() {
    let (mut r, _g) = rig("slimm-data-ops").await;
    let inserted = r.ok(json!({ "op": "insert", "table": "xp",
        "values": { "user_id": "u1", "points": 5, "ratio": 1.5, "active": false } }));
    assert_eq!(inserted["changed"], json!(1));
    assert_eq!(inserted["rows"][0]["_id"], json!(1));

    let got = r.ok(json!({ "op": "get", "table": "xp",
        "where": [{ "col": "user_id", "op": "eq", "val": "u1" }] }));
    assert_eq!(
        got["rows"][0],
        json!({ "_id": 1, "user_id": "u1", "points": 5, "ratio": 1.5, "active": false })
    );

    let updated = r.ok(
        json!({ "op": "update", "table": "xp", "values": { "active": true },
        "where": [{ "col": "_id", "op": "eq", "val": 1 }] }),
    );
    assert_eq!(updated["changed"], json!(1));
    let after = r.ok(json!({ "op": "get", "table": "xp" }));
    assert_eq!(after["rows"][0]["active"], json!(true));

    assert_eq!(
        r.ok(json!({ "op": "count", "table": "xp" }))["count"],
        json!(1)
    );
    let deleted = r.ok(json!({ "op": "delete", "table": "xp",
        "where": [{ "col": "user_id", "op": "eq", "val": "u1" }] }));
    assert_eq!(deleted["changed"], json!(1));
    assert_eq!(
        r.ok(json!({ "op": "count", "table": "xp" }))["count"],
        json!(0)
    );
    let none = r.ok(json!({ "op": "get", "table": "xp" }));
    assert_eq!(none["rows"], json!([]));
}

#[tokio::test(flavor = "multi_thread")]
async fn every_where_operator_filters() {
    let (mut r, _g) = rig("slimm-data-where").await;
    for (user, points) in [("ann", 10), ("bob", 20), ("cyd", 30), ("a_n", 40)] {
        add(&mut r, user, points);
    }
    let query = |r: &mut Rig, op: &str, val: Value| {
        names(&r.ok(json!({ "op": "query", "table": "xp",
            "where": [{ "col": "points", "op": op, "val": val }],
            "order": [{ "col": "points" }] })))
    };
    assert_eq!(query(&mut r, "eq", json!(20)), ["bob"]);
    assert_eq!(query(&mut r, "ne", json!(20)), ["ann", "cyd", "a_n"]);
    assert_eq!(query(&mut r, "gt", json!(20)), ["cyd", "a_n"]);
    assert_eq!(query(&mut r, "gte", json!(20)), ["bob", "cyd", "a_n"]);
    assert_eq!(query(&mut r, "lt", json!(20)), ["ann"]);
    assert_eq!(query(&mut r, "lte", json!(20)), ["ann", "bob"]);
    assert_eq!(query(&mut r, "in", json!([10, 30, 99])), ["ann", "cyd"]);

    let like = |r: &mut Rig, pattern: &str| {
        names(&r.ok(json!({ "op": "query", "table": "xp",
            "where": [{ "col": "user_id", "op": "like", "val": pattern }],
            "order": [{ "col": "points" }] })))
    };
    assert_eq!(like(&mut r, "a%"), ["ann", "a_n"]);
    assert_eq!(like(&mut r, "a\\_n"), ["a_n"]);
    assert_eq!(like(&mut r, "a_n"), ["ann", "a_n"]);

    let anded = r.ok(json!({ "op": "query", "table": "xp", "where": [
        { "col": "points", "op": "gt", "val": 10 }, { "col": "points", "op": "lt", "val": 40 }] }));
    assert_eq!(names(&anded), ["bob", "cyd"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn order_limit_and_offset_page_through_rows() {
    let (mut r, _g) = rig("slimm-data-page").await;
    for i in 0..5 {
        add(&mut r, &format!("u{i}"), i);
    }
    let page = r.ok(
        json!({ "op": "query", "table": "xp", "limit": 2, "offset": 1,
        "order": [{ "col": "points", "dir": "desc" }] }),
    );
    assert_eq!(names(&page), ["u3", "u2"]);
    assert_eq!(page["count"], json!(2));
    assert!(
        r.refused(json!({ "op": "query", "table": "xp", "limit": 201 }))
            .contains("limit")
    );
    assert!(
        r.refused(json!({ "op": "query", "table": "xp", "limit": 0 }))
            .contains("limit")
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn an_xp_leaderboard_upserts_increments_ranks_and_totals() {
    let (mut r, _g) = rig("slimm-data-xp").await;
    for i in 0..12 {
        r.ok(json!({ "op": "upsert", "table": "xp", "on": "user_id",
            "values": { "user_id": format!("u{i:02}"), "points": i } }));
    }
    // Upserting again updates in place instead of adding a row.
    r.ok(json!({ "op": "upsert", "table": "xp", "on": ["user_id"],
        "values": { "user_id": "u00", "points": 5 } }));
    assert_eq!(
        r.ok(json!({ "op": "count", "table": "xp" }))["count"],
        json!(12)
    );
    let bumped = r.ok(
        json!({ "op": "increment", "table": "xp", "col": "points", "by": 100,
        "where": [{ "col": "user_id", "op": "eq", "val": "u03" }] }),
    );
    assert_eq!(bumped["changed"], json!(1));
    r.ok(json!({ "op": "increment", "table": "xp", "col": "points",
        "where": [{ "col": "user_id", "op": "eq", "val": "u03" }] }));

    let top = r.ok(json!({ "op": "query", "table": "xp", "limit": 10,
        "order": [{ "col": "points", "dir": "desc" }] }));
    assert_eq!(top["rows"].as_array().unwrap().len(), 10);
    assert_eq!(top["rows"][0]["user_id"], json!("u03"));
    assert_eq!(top["rows"][0]["points"], json!(104));
    assert_eq!(top["rows"][1]["user_id"], json!("u11"));
    // 0..12 sums to 66, u00 became 5 (+5), and u03 gained 101.
    let total = r.ok(json!({ "op": "sum", "table": "xp", "col": "points" }));
    assert_eq!(total["count"], json!(66 + 5 + 101));
    let empty = r.ok(json!({ "op": "sum", "table": "xp", "col": "points",
        "where": [{ "col": "points", "op": "gt", "val": 100000 }] }));
    assert_eq!(empty["count"], json!(0));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_unique_column_refuses_a_duplicate_and_real_sums_stay_real() {
    let (mut r, _g) = rig("slimm-data-unique").await;
    add(&mut r, "u1", 1);
    let error = r.refused(json!({ "op": "insert", "table": "xp", "values": { "user_id": "u1" } }));
    assert!(error.contains("unique"), "{error}");
    add(&mut r, "u2", 2);
    let sum = r.ok(json!({ "op": "sum", "table": "xp", "col": "ratio" }));
    assert_eq!(sum["count"], json!(1.0));
}

#[tokio::test(flavor = "multi_thread")]
async fn malformed_requests_are_refused_cleanly() {
    let (mut r, _g) = rig("slimm-data-bad").await;
    for request in [
        json!({ "op": "insert", "table": "xp" }),
        json!({ "op": "insert", "table": "xp", "values": { "points": "many" } }),
        json!({ "op": "insert", "table": "xp", "values": { "points": 1.5 } }),
        json!({ "op": "insert", "table": "xp", "values": { "_id": 9 } }),
        json!({ "op": "insert", "table": "xp", "values": { "user_id": "x".repeat(4097) } }),
        json!({ "op": "update", "table": "xp", "values": {} }),
        json!({ "op": "upsert", "table": "xp", "values": { "user_id": "a" } }),
        json!({ "op": "upsert", "table": "xp", "on": "points", "values": { "points": 1 } }),
        json!({ "op": "upsert", "table": "xp", "on": "user_id", "values": { "points": 1 } }),
        json!({ "op": "sum", "table": "xp", "col": "user_id" }),
        json!({ "op": "sum", "table": "xp" }),
        json!({ "op": "query", "table": "xp", "where": [{ "col": "points", "op": "in", "val": [] }] }),
        json!({ "op": "query", "table": "xp", "where": [{ "col": "points", "op": "like", "val": "1" }] }),
        json!({ "op": "query", "table": "xp", "order": [{ "col": "points", "dir": "sideways" }] }),
        json!({ "op": "teleport", "table": "xp" }),
        json!({ "table": "xp" }),
    ] {
        let reply = r.store(request.clone());
        assert_eq!(reply["ok"], json!(false), "{request} -> {reply}");
    }
    assert!(
        r.store(json!({ "op": "insert", "table": "xp", "values": { "user_id": "ok" } }))["ok"]
            == json!(true)
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn hostile_input_is_refused_or_stored_as_plain_data() {
    let (mut r, _g) = rig("slimm-data-inject").await;
    add(&mut r, "victim", 1);
    let drop_it = "x\"; DROP TABLE xp; --";
    for request in [
        json!({ "op": "query", "table": drop_it }),
        json!({ "op": "query", "table": "xp\" --" }),
        json!({ "op": "query", "table": "sqlite_master" }),
        json!({ "op": "query", "table": "_slim_meta" }),
        json!({ "op": "query", "table": "xp", "where": [{ "col": drop_it, "op": "eq", "val": 1 }] }),
        json!({ "op": "query", "table": "xp", "where": [{ "col": "points; DROP TABLE xp", "op": "eq", "val": 1 }] }),
        json!({ "op": "query", "table": "xp", "where": [{ "col": "points", "op": "eq OR 1=1", "val": 1 }] }),
        json!({ "op": "query", "table": "xp", "order": [{ "col": "points; DROP TABLE xp" }] }),
        json!({ "op": "query", "table": "xp", "order": [{ "col": "points", "dir": "desc; DROP TABLE xp" }] }),
        json!({ "op": "insert", "table": "xp", "values": { drop_it: 1 } }),
        json!({ "op": "sum", "table": "xp", "col": "points) FROM xp; DROP TABLE xp; --" }),
        json!({ "op": "upsert", "table": "xp", "on": drop_it, "values": { "user_id": "a" } }),
        json!({ "op": "increment", "table": "xp", "col": drop_it, "by": 1 }),
        json!({ "op": "query", "table": "xp", "limit": "1; DROP TABLE xp" }),
    ] {
        let reply = r.store(request.clone());
        assert_eq!(reply["ok"], json!(false), "{request} -> {reply}");
    }
    // As values the same text is just text, bound and never parsed.
    let payload = "'); DROP TABLE xp; --";
    r.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": payload } }));
    let found = r.ok(json!({ "op": "query", "table": "xp",
        "where": [{ "col": "user_id", "op": "eq", "val": payload }] }));
    assert_eq!(names(&found), [payload]);
    let like_all = r.ok(json!({ "op": "query", "table": "xp",
        "where": [{ "col": "user_id", "op": "like", "val": "' OR '1'='1" }] }));
    assert_eq!(like_all["rows"], json!([]));
    let still = r.ok(json!({ "op": "count", "table": "xp" }));
    assert_eq!(still["count"], json!(2));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_real_amount_that_could_overflow_is_refused_and_an_overflowing_sum_is_not_null() {
    let (mut r, _g) = rig("slimm-data-real-overflow").await;
    r.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "a", "ratio": 1.7e308 } }));
    r.ok(json!({ "op": "insert", "table": "xp", "values": { "user_id": "b", "ratio": 1.7e308 } }));

    let huge =
        r.refused(json!({ "op": "increment", "table": "xp", "col": "ratio", "by": 1.0e308 }));
    assert!(huge.contains("out of range"), "{huge}");
    let upsert = r.refused(json!({ "op": "upsert", "table": "xp", "on": "user_id",
        "values": { "user_id": "a" }, "add": { "ratio": 1.0e308 } }));
    assert!(upsert.contains("out of range"), "{upsert}");
    r.ok(json!({ "op": "increment", "table": "xp", "col": "ratio", "by": 4.5 }));

    let sum = r.refused(json!({ "op": "sum", "table": "xp", "col": "ratio" }));
    assert!(!sum.is_empty(), "an infinite total is an error, not a null");
}
