// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Debug logs members send to the admins: the size cap, the note, the rate
//! limit, the admin-only list, read and delete, and the retention sweep.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::store::{DEBUG_LOGS_PER_USER, NewDebugLog, Store};

mod support;

use support::app::call;

struct World {
    app: Router,
    store: Store,
    admin: String,
    member: String,
    member_id: slimm_server::ids::UserId,
    _db: support::TestDbGuard,
}

async fn world(prefix: &str) -> World {
    let (store, db) = support::new_store(prefix).await;
    let admin = support::app::register_account(&store, "root").await;
    let member = support::app::register_account(&store, "nia").await;
    World {
        app: support::app::app(store.clone()),
        store,
        admin: admin.token,
        member: member.token,
        member_id: member.id,
        _db: db,
    }
}

async fn post(w: &World, token: &str, body: Value) -> (StatusCode, Value) {
    call(&w.app, "POST", "/debug-logs", Some(token), Some(body)).await
}

async fn get(w: &World, uri: &str, token: &str) -> (StatusCode, Value) {
    call(&w.app, "GET", uri, Some(token), None).await
}

async fn delete(w: &World, uri: &str, token: &str) -> StatusCode {
    call(&w.app, "DELETE", uri, Some(token), None).await.0
}

fn payload(log: &str, note: &str) -> Value {
    json!({"log": log, "note": note, "app_version": "0.1.0", "platform": "linux"})
}

#[tokio::test]
async fn a_member_sends_a_log_and_an_admin_reads_it_back() {
    let w = world("debug_logs_roundtrip").await;
    let (status, sent) = post(
        &w,
        &w.member,
        payload("12:00:00  ERROR  [sync]  failed", "  my settings reset  "),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let id = sent["id"].as_i64().unwrap();

    let (_, list) = get(&w, "/debug-logs", &w.admin).await;
    let entry = &list[0];
    assert_eq!(entry["id"], id);
    assert_eq!(entry["username"], "nia");
    assert_eq!(entry["user_id"], w.member_id.to_string());
    assert_eq!(entry["note"], "my settings reset");
    assert_eq!(entry["platform"], "linux");
    assert_eq!(entry["app_version"], "0.1.0");
    assert_eq!(entry["size_bytes"], 31);
    assert!(
        entry.get("log").is_none(),
        "the list never carries the text"
    );

    let (_, one) = get(&w, &format!("/debug-logs/{id}"), &w.admin).await;
    assert_eq!(one["log"], "12:00:00  ERROR  [sync]  failed");

    let status = delete(&w, &format!("/debug-logs/{id}"), &w.admin).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, list) = get(&w, "/debug-logs", &w.admin).await;
    assert_eq!(list.as_array().unwrap().len(), 0);
    let status = delete(&w, &format!("/debug-logs/{id}"), &w.admin).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_log_over_one_mebibyte_is_refused_with_a_reason() {
    let w = world("debug_logs_cap").await;
    let big = "x".repeat(1024 * 1024 + 1);
    let (status, body) = post(&w, &w.member, payload(&big, "")).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"].as_str().unwrap().contains("1 MiB"), "{body}");

    let exact = "x".repeat(1024 * 1024);
    let (status, _) = post(&w, &w.member, payload(&exact, "")).await;
    assert_eq!(status, StatusCode::CREATED);
}

#[tokio::test]
async fn an_empty_log_a_long_note_and_blank_labels_are_refused() {
    let w = world("debug_logs_validation").await;
    for body in [
        payload("  ", ""),
        payload("log", &"n".repeat(501)),
        json!({"log": "log", "app_version": " ", "platform": "linux"}),
        json!({"log": "log", "app_version": "1", "platform": "p".repeat(65)}),
        json!({"log": "log", "app_version": "1", "platform": "li\u{202e}nux"}),
    ] {
        let (status, _) = post(&w, &w.member, body).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    let (status, _) = post(&w, &w.member, payload("log", &"n".repeat(500))).await;
    assert_eq!(status, StatusCode::CREATED);
}

#[tokio::test]
async fn submitting_is_rate_limited_per_member() {
    let w = world("debug_logs_rate").await;
    let mut refused = None;
    for _ in 0..30 {
        let (status, _) = post(&w, &w.member, payload("log", "")).await;
        if status == StatusCode::TOO_MANY_REQUESTS {
            refused = Some(status);
            break;
        }
    }
    assert_eq!(refused, Some(StatusCode::TOO_MANY_REQUESTS));
    let (status, _) = post(&w, &w.admin, payload("log", "")).await;
    assert_eq!(
        status,
        StatusCode::CREATED,
        "another member has their own budget"
    );
}

#[tokio::test]
async fn only_an_admin_lists_reads_or_deletes() {
    let w = world("debug_logs_admin_only").await;
    let (_, sent) = post(&w, &w.member, payload("log", "")).await;
    let uri = format!("/debug-logs/{}", sent["id"]);
    for (status, what) in [
        (get(&w, "/debug-logs", &w.member).await.0, "list"),
        (get(&w, &uri, &w.member).await.0, "read"),
        (delete(&w, &uri, &w.member).await, "delete"),
    ] {
        assert_eq!(status, StatusCode::FORBIDDEN, "{what}");
    }
    let (status, _) = get(&w, "/debug-logs", "not-a-token").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn a_member_keeps_only_their_newest_logs() {
    let w = world("debug_logs_per_user").await;
    let member = w.member_id;
    let mut first = 0;
    for n in 0..=DEBUG_LOGS_PER_USER {
        let log = format!("log {n}");
        let new = NewDebugLog {
            note: "",
            app_version: "1",
            platform: "linux",
            log: &log,
        };
        let (id, _) = w.store.submit_debug_log(member, &new).await.unwrap();
        if n == 0 {
            first = id;
        }
    }
    let rows = w.store.list_debug_logs(None, 100).await.unwrap();
    assert_eq!(rows.len() as i64, DEBUG_LOGS_PER_USER);
    assert!(rows.iter().all(|r| r.id != first), "the oldest went");
}

#[tokio::test]
async fn the_sweep_drops_logs_older_than_thirty_days() {
    let w = world("debug_logs_sweep").await;
    let (_, sent) = post(&w, &w.member, payload("log", "")).await;
    let created = sent["created_at"].as_i64().unwrap();
    let day = 24 * 60 * 60 * 1000;
    assert_eq!(
        w.store
            .sweep_debug_logs_at(created + 29 * day)
            .await
            .unwrap(),
        0
    );
    assert_eq!(
        w.store
            .sweep_debug_logs_at(created + 31 * day)
            .await
            .unwrap(),
        1
    );
    assert!(w.store.list_debug_logs(None, 10).await.unwrap().is_empty());
}
