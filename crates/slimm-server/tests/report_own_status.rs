// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /reports/mine/{reportId}`: a reporter's narrow, status-only read of a
//! report they filed themselves.
//!
//! Before this route, every report-reading surface (`/reports`,
//! `/reports/history`, and resolving one) sat behind deployment-wide
//! MANAGE_MESSAGES, so a reporter could not confirm their own report had
//! reached anyone at all. This is the one exception: no permission gate,
//! just an ownership filter applied in the query itself, and the answer it
//! gives back is deliberately smaller than what a moderator sees.
//!
//! The security property this file exists to prove is the masking rule from
//! docs/decisions/0011-per-channel-permissions.md: a report id that belongs
//! to someone else must be indistinguishable from one that never existed,
//! not merely refused by a different path that happens to also fail.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::{MessageId, UserId};
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, ReportSubject, Store};
use tower::ServiceExt;

mod support;
use support::reports::StoreReportExt;

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

fn app(store: Store) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn get(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

/// A fresh account with a session, for signing requests.
async fn account(store: &Store, username: &str) -> (UserId, String) {
    let user = store
        .create_user(username, username)
        .await
        .expect("create user");
    let token = store
        .open_session(user.id, "cli")
        .await
        .expect("open session")
        .access_token;
    (user.id, token)
}

/// Files a report about a fresh message as `reporter`, returning its id.
async fn file_report_as(store: &Store, author: UserId, reporter: UserId, body: &str) -> String {
    let channel = store.list_channels().await.unwrap()[0].id;
    let message = store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            body,
        ))
        .await
        .unwrap()
        .message
        .id;
    store
        .file_report(reporter, ReportSubject::Message(message), "not ok")
        .await
        .unwrap()
        .to_string()
}

async fn response_for(app: &Router, uri: &str, token: &str) -> (StatusCode, Vec<u8>) {
    let response = app.clone().oneshot(get(uri, token)).await.unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, bytes.to_vec())
}

/// The deliverable's positive case: a reporter can read their own report's
/// status with no MANAGE_MESSAGES bit anywhere on their account.
#[tokio::test]
async fn a_reporter_sees_their_own_report_status() {
    let (store, _guard) = new_store("slimm-report-own-status-self").await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let (reporter_id, reporter_token) = account(&store, "reporter").await;

    let report_id = file_report_as(&store, admin.id, reporter_id, "spammy").await;

    let app = app(store.clone());
    let (status, body) =
        response_for(&app, &format!("/reports/mine/{report_id}"), &reporter_token).await;
    assert_eq!(status, StatusCode::OK);

    let json: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["id"], Value::String(report_id));
    assert_eq!(json["subject_kind"], Value::String("message".into()));
    assert_eq!(json["status"], Value::String("open".into()));
    assert!(json["created_at"].is_i64());

    // Nothing a moderator's own view carries is present here.
    assert!(json.get("reporter_id").is_none());
    assert!(json.get("snapshot").is_none());
    assert!(json.get("subject_author_id").is_none());
    assert!(json.get("resolved_by").is_none());
    assert!(json.get("resolution").is_none());
}

/// The security property: a report id that belongs to someone else must
/// answer exactly as a report id that names nobody at all, byte for byte,
/// not merely with the same status code by coincidence.
#[tokio::test]
async fn another_reporters_report_id_404s_identically_to_nonexistent() {
    let (store, _guard) = new_store("slimm-report-own-status-mask").await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let (alice_id, _alice_token) = account(&store, "alice").await;
    let (_bob_id, bob_token) = account(&store, "bob").await;

    let alices_report = file_report_as(&store, admin.id, alice_id, "alice-filed-this").await;
    let nonexistent = uuid::Uuid::now_v7().to_string();

    let app = app(store.clone());
    let owned_by_someone_else =
        response_for(&app, &format!("/reports/mine/{alices_report}"), &bob_token).await;
    let never_existed =
        response_for(&app, &format!("/reports/mine/{nonexistent}"), &bob_token).await;

    assert_eq!(
        owned_by_someone_else.0,
        StatusCode::NOT_FOUND,
        "bob must not be able to read alice's report"
    );
    assert_eq!(
        owned_by_someone_else, never_existed,
        "a report bob does not own must be indistinguishable, status and body alike, \
         from an id naming no report at all: {owned_by_someone_else:?} vs {never_existed:?}"
    );

    // A stronger check than the status code alone: alice's text never reached bob.
    let serialized = String::from_utf8_lossy(&owned_by_someone_else.1);
    assert!(!serialized.contains("alice-filed-this"));
}

/// Resolving the report flips the status this route reports, and nothing
/// else about the shape.
#[tokio::test]
async fn the_resolved_status_is_accurate() {
    let (store, _guard) = new_store("slimm-report-own-status-resolved").await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let (reporter_id, reporter_token) = account(&store, "reporter").await;

    let report_id = file_report_as(&store, admin.id, reporter_id, "resolve-me").await;
    store
        .resolve_report(
            uuid::Uuid::parse_str(&report_id).unwrap(),
            admin.id,
            "resolved",
        )
        .await
        .unwrap();

    let app = app(store.clone());
    let (status, body) =
        response_for(&app, &format!("/reports/mine/{report_id}"), &reporter_token).await;
    assert_eq!(status, StatusCode::OK);
    let json: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["status"], Value::String("resolved".into()));
    // Never the finer resolved/dismissed label; see MyReportStatusDto's own doc.
    assert!(json.get("resolution").is_none());
}

/// The moderator-facing surfaces this route sits beside are unchanged: the
/// queue still requires MANAGE_MESSAGES and still carries the full shape.
#[tokio::test]
async fn a_moderators_existing_surface_is_unchanged() {
    let (store, _guard) = new_store("slimm-report-own-status-mod-unchanged").await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let (reporter_id, _reporter_token) = account(&store, "reporter").await;
    let (_bystander_id, bystander_token) = account(&store, "bystander").await;

    let report_id = file_report_as(&store, admin.id, reporter_id, "for-the-queue").await;

    let app = app(store.clone());

    // A caller with no MANAGE_MESSAGES still cannot read the moderator queue.
    let (status, _) = response_for(&app, "/reports", &bystander_token).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // The deployment admin still reads the full moderator shape, snapshot included.
    let admin_token = store
        .open_session(admin.id, "cli")
        .await
        .unwrap()
        .access_token;
    let (status, body) = response_for(&app, "/reports", &admin_token).await;
    assert_eq!(status, StatusCode::OK);
    let queue: Value = serde_json::from_slice(&body).unwrap();
    let entry = queue
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == Value::String(report_id.clone()))
        .expect("the filed report is in the moderator queue");
    assert_eq!(entry["snapshot"], Value::String("for-the-queue".into()));
    assert_eq!(entry["reporter_id"], Value::String(reporter_id.to_string()));
}
