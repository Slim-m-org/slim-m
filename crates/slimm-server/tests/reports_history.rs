// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! MOD4: `GET /reports/history`, the merged read over resolved reports and
//! `moderation_audit_log` that `reports.rs` (open queue) and
//! `moderation_audit_routes.rs` (write-only until now) never gave a reader.
//!
//! Its own file rather than added to `reports.rs`, past the review budget
//! already; see that file's own closing comment.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token_id as register, request};

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

async fn general_channel_id(store: &Store) -> String {
    store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .find(|c| c.name == "general")
        .expect("bootstrap seeds a general channel")
        .id
        .to_string()
}

/// Sends a message as `author_token` and files a report on it as
/// `reporter_token`, returning the report id.
async fn file_a_report(
    app: &Router,
    channel_id: &str,
    author_token: &str,
    reporter_token: &str,
    content: &str,
) -> String {
    let sent = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel_id}/messages"),
                Some(author_token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let message_id = sent["id"].as_str().unwrap();

    let filed = app
        .clone()
        .oneshot(request(
            "POST",
            "/reports",
            Some(reporter_token),
            Some(json!({
                "subject_kind": "message",
                "subject_id": message_id,
                "reason": "spam"
            })),
        ))
        .await
        .unwrap();
    assert_eq!(filed.status(), StatusCode::OK);
    json_body(filed).await["id"].as_str().unwrap().to_owned()
}

async fn send(app: &Router, channel: ChannelId, token: &str, content: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel}/messages"),
                Some(token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await
}

async fn open_thread(app: &Router, channel: ChannelId, message_id: &str, token: &str) -> ChannelId {
    let opened = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel}/messages/{message_id}/thread"),
                Some(token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    ChannelId(Uuid::parse_str(opened["id"].as_str().unwrap()).unwrap())
}

/// Files a report on an already-sent message, returning the report id. The
/// counterpart to `file_a_report`, which also sends the message itself; a
/// thread reply is sent through `open_thread` first, so this only files.
async fn file_report_on(app: &Router, message_id: &str, reporter_token: &str) -> String {
    let filed = app
        .clone()
        .oneshot(request(
            "POST",
            "/reports",
            Some(reporter_token),
            Some(json!({
                "subject_kind": "message",
                "subject_id": message_id,
                "reason": "spam"
            })),
        ))
        .await
        .unwrap();
    assert_eq!(filed.status(), StatusCode::OK);
    json_body(filed).await["id"].as_str().unwrap().to_owned()
}

/// A moderator holding deployment-wide MANAGE_MESSAGES through a role, but
/// denied VIEW_CHANNEL on `channel` by a member overwrite - the same shape
/// `report_thread_scoping.rs`'s own `restricted_moderator` uses, denying
/// VIEW_CHANNEL rather than MANAGE_MESSAGES since that is the bit
/// `report_view_channel_scoping.rs` covers for the open queue and this test
/// mirrors for the history feed.
async fn view_denied_moderator(store: &Store, channel: ChannelId) -> (UserId, String) {
    let account = store
        .create_account("carol", "carol", "not-a-real-hash")
        .await
        .unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    let role = store
        .create_role("moderator", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    store.assign_role(account.id, role).await.unwrap();
    store
        .set_member_overwrite(
            channel,
            account.id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    (account.id, tokens.access_token)
}

#[tokio::test]
async fn history_requires_manage_messages() {
    let (store, _guard) = new_store("slimm-reports-history-gate").await;
    let app = app(store.clone());
    let (_admin_token, _admin_id) = register(&store, "alice").await;
    let (bob_token, _bob_id) = register(&store, "bob").await;

    let response = app
        .clone()
        .oneshot(request("GET", "/reports/history", Some(&bob_token), None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// The load-bearing test: a resolved report and an audit-log entry both
/// appear, newest first, and an open (unresolved) report does not appear at
/// all - the exact gap MOD4 closes.
#[tokio::test]
async fn history_carries_a_resolved_report_and_an_audit_entry_newest_first() {
    let (store, _guard) = new_store("slimm-reports-history-feed").await;
    let app = app(store.clone());
    let (admin_token, admin_id) = register(&store, "alice").await;
    let (bob_token, _bob_id) = register(&store, "bob").await;
    let (carol_token, _carol_id) = register(&store, "carol").await;
    let channel_id = general_channel_id(&store).await;
    let admin = UserId(Uuid::parse_str(&admin_id).unwrap());

    // An audit-log entry, oldest of the two events.
    store
        .set_member_timeout(admin, now_ms() + 3_600_000, Some("cool off"), admin)
        .await
        .unwrap();

    // A resolved report, filed and closed after the timeout above.
    let resolved_id =
        file_a_report(&app, &channel_id, &bob_token, &carol_token, "resolved one").await;
    let resolve = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/reports/{resolved_id}"),
            Some(&admin_token),
            Some(json!({ "resolution": "resolved" })),
        ))
        .await
        .unwrap();
    assert_eq!(resolve.status(), StatusCode::NO_CONTENT);

    // An open report, never resolved - must not appear in the history feed.
    let open_id = file_a_report(&app, &channel_id, &bob_token, &carol_token, "still open").await;

    let history = json_body(
        app.clone()
            .oneshot(request("GET", "/reports/history", Some(&admin_token), None))
            .await
            .unwrap(),
    )
    .await;
    let items = history.as_array().unwrap();

    assert!(
        items.iter().all(|item| item["id"] != open_id),
        "an open report must never appear in the history feed: {items:?}"
    );

    assert_eq!(
        items.len(),
        2,
        "expected exactly the resolved report and the audit entry: {items:?}"
    );
    assert_eq!(
        items[0]["kind"], "resolved_report",
        "newest event (the resolve) is first: {items:?}"
    );
    assert_eq!(items[0]["id"], resolved_id);
    assert_eq!(items[0]["resolution"], "resolved");
    assert_eq!(items[0]["snapshot"], "resolved one");
    assert_eq!(
        items[1]["kind"], "audit_log",
        "the older event (the timeout) is second: {items:?}"
    );
    assert_eq!(items[1]["action"], "timeout");
    assert_eq!(items[1]["subject_id"], admin_id);
}

/// The privacy leak an adversarial review found: `open_report_channel_ids`
/// stops naming a thread's channel the instant its one report closes, so a
/// naive reuse of the open queue's own hidden-channel walk for this route
/// would let a RESOLVED thread report past a moderator denied VIEW_CHANNEL
/// on the thread's parent - the reporter id, the verbatim snapshot, and the
/// subject's author id, all leaked. `report_view_channel_scoping.rs` already
/// proves the open queue closes this; this is its mirror for the history
/// feed, on a report that has since been resolved.
#[tokio::test]
async fn a_moderator_denied_view_on_the_parent_cannot_see_a_resolved_thread_report() {
    let (store, _guard) = new_store("slimm-reports-history-thread-denied").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_token, _bob_id) = register(&store, "bob").await;
    let (_carol_id, carol_token) = view_denied_moderator(&store, channel).await;

    let seed = send(&app, channel, &bob_token, "seed").await;
    let seed_id = seed["id"].as_str().unwrap().to_owned();
    let thread = open_thread(&app, channel, &seed_id, &bob_token).await;
    let reply = send(&app, thread, &bob_token, "reply content").await;
    let reply_id = reply["id"].as_str().unwrap().to_owned();

    let report_id = file_report_on(&app, &reply_id, &admin_token).await;
    let resolve = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/reports/{report_id}"),
            Some(&admin_token),
            Some(json!({ "resolution": "resolved" })),
        ))
        .await
        .unwrap();
    assert_eq!(resolve.status(), StatusCode::NO_CONTENT);

    let history = json_body(
        app.clone()
            .oneshot(request("GET", "/reports/history", Some(&carol_token), None))
            .await
            .unwrap(),
    )
    .await;
    let items = history.as_array().unwrap();
    assert!(
        items.iter().all(|item| item["id"] != report_id),
        "a resolved report about a thread reply must stay hidden from a \
         moderator denied VIEW_CHANNEL on the thread's parent, the same as \
         an open one: {items:?}"
    );
}

/// The positive case: a moderator who can still view the parent channel
/// sees a resolved report about one of its threads in the history feed.
#[tokio::test]
async fn a_moderator_who_can_view_the_parent_sees_a_resolved_thread_report() {
    let (store, _guard) = new_store("slimm-reports-history-thread-allowed").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_token, bob_id) = register(&store, "bob").await;
    let bob = UserId(Uuid::parse_str(&bob_id).unwrap());

    let moderator = store
        .create_role("moderator", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    store.assign_role(bob, moderator).await.unwrap();

    let seed = send(&app, channel, &admin_token, "seed").await;
    let seed_id = seed["id"].as_str().unwrap().to_owned();
    let thread = open_thread(&app, channel, &seed_id, &admin_token).await;
    let reply = send(&app, thread, &admin_token, "reply content").await;
    let reply_id = reply["id"].as_str().unwrap().to_owned();

    let report_id = file_report_on(&app, &reply_id, &bob_token).await;
    let resolve = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/reports/{report_id}"),
            Some(&bob_token),
            Some(json!({ "resolution": "resolved" })),
        ))
        .await
        .unwrap();
    assert_eq!(resolve.status(), StatusCode::NO_CONTENT);

    let history = json_body(
        app.clone()
            .oneshot(request("GET", "/reports/history", Some(&bob_token), None))
            .await
            .unwrap(),
    )
    .await;
    let items = history.as_array().unwrap();
    assert!(
        items.iter().any(|item| item["id"] == report_id),
        "a moderator who can view the parent must still see its thread's \
         resolved reports: {items:?}"
    );
}

/// `VIEW_MODERATION_HISTORY` clears this gate on its own, and - unlike
/// `MANAGE_MESSAGES` - skips `hidden_channels`'s per-channel filter: the
/// modlog bot (0028's addendum) holds no per-channel `MANAGE_MESSAGES` grant
/// anywhere for that filter to find. So a resolved report about a channel
/// this caller cannot moderate must still appear, alongside a deployment-wide
/// audit entry.
#[tokio::test]
async fn view_moderation_history_bit_reads_without_manage_messages_or_channel_scoping() {
    let (store, _guard) = new_store("slimm-reports-history-view-only").await;
    let app = app(store.clone());
    let (admin_token, admin_id) = register(&store, "alice").await;
    let (bob_token, _bob_id) = register(&store, "bob").await;
    let (carol_token, _carol_id) = register(&store, "carol").await;
    let channel_id = general_channel_id(&store).await;
    let admin = UserId(Uuid::parse_str(&admin_id).unwrap());

    let reader = store
        .create_account("modlog", "modlog", "not-a-real-hash")
        .await
        .unwrap();
    let reader_tokens = store.open_session(reader.id, "cli").await.unwrap();
    let reader_role = store
        .create_role("reader", Permissions::VIEW_MODERATION_HISTORY, false)
        .await
        .unwrap();
    store.assign_role(reader.id, reader_role).await.unwrap();

    // A deployment-wide audit entry, with no channel at all.
    store
        .set_member_timeout(admin, now_ms() + 3_600_000, Some("cool off"), admin)
        .await
        .unwrap();

    // `reader` holds no MANAGE_MESSAGES anywhere; see this test's own doc.
    let resolved_id =
        file_a_report(&app, &channel_id, &bob_token, &carol_token, "resolved one").await;
    let resolve = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/reports/{resolved_id}"),
            Some(&admin_token),
            Some(json!({ "resolution": "resolved" })),
        ))
        .await
        .unwrap();
    assert_eq!(resolve.status(), StatusCode::NO_CONTENT);

    let reader_token = reader_tokens.access_token.as_str();
    let response = app
        .clone()
        .oneshot(request("GET", "/reports/history", Some(reader_token), None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let items = json_body(response).await;
    let items = items.as_array().unwrap();

    let is_timeout = |i: &Value| i["kind"] == "audit_log" && i["action"] == "timeout";
    assert!(
        items.iter().any(is_timeout),
        "the deployment-wide audit entry must be visible: {items:?}"
    );
    assert!(
        items.iter().any(|i| i["id"] == resolved_id),
        "a resolved report in an unmoderated channel must still show: {items:?}"
    );

    // The live queue still needs MANAGE_MESSAGES; this bit does not open it.
    let queue = app
        .clone()
        .oneshot(request("GET", "/reports", Some(reader_token), None))
        .await
        .unwrap();
    assert_eq!(queue.status(), StatusCode::FORBIDDEN);
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}
