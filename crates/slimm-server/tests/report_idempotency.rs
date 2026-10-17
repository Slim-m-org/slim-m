// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `fileReport` is idempotent by a client-minted id, like every other durable
//! write. Before this, a client that timed out and retried got 409 for a
//! report it had no way to find; now the same id replays the same report, a
//! reused id naming something else is a conflict, and the one-open-report-per-
//! subject rule still holds under a fresh id.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::MessageId;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;
use uuid::Uuid;

mod support;

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

fn post(uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn get(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// An admin, a reporter, and one of the admin's messages to report. Returns
/// the router plus (admin token, reporter token, admin id, message id).
async fn scene() -> (Router, String, String, String, String, support::TestDbGuard) {
    let (store, guard) = support::new_store("slimm-report-idem").await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let bob = store
        .create_account("bob", "Bob", "not-a-real-hash")
        .await
        .unwrap();
    let message = store
        .send_message(NewMessage::plain(
            channel,
            admin.id,
            MessageId::generate(),
            "hi",
        ))
        .await
        .unwrap()
        .message
        .id;
    let admin_token = store
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let bob_token = store
        .open_session(bob.id, "phone")
        .await
        .unwrap()
        .access_token;
    (
        app(store),
        admin_token,
        bob_token,
        admin.id.to_string(),
        message.to_string(),
        guard,
    )
}

fn report(id: &Uuid, kind: &str, subject: &str) -> Value {
    json!({ "id": id.to_string(), "subject_kind": kind, "subject_id": subject, "reason": "spam" })
}

#[tokio::test]
async fn a_retry_with_the_same_id_replays_the_same_report_once() {
    let (app, admin, bob, _admin_id, message, _guard) = scene().await;
    let id = Uuid::now_v7();

    let first = app
        .clone()
        .oneshot(post("/reports", &bob, report(&id, "message", &message)))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    let second = app
        .clone()
        .oneshot(post("/reports", &bob, report(&id, "message", &message)))
        .await
        .unwrap();
    assert_eq!(
        second.status(),
        StatusCode::OK,
        "a retry is not a duplicate"
    );

    let first_id = json_body(first).await["id"].as_str().unwrap().to_owned();
    let second_id = json_body(second).await["id"].as_str().unwrap().to_owned();
    assert_eq!(
        first_id,
        id.to_string(),
        "the client's id is the report's id"
    );
    assert_eq!(second_id, first_id, "the replay names the same report");

    let queue = json_body(app.oneshot(get("/reports", &admin)).await.unwrap()).await;
    assert_eq!(
        queue.as_array().map(Vec::len),
        Some(1),
        "one filing, however many times it was retried: {queue}"
    );
}

#[tokio::test]
async fn the_same_id_naming_a_different_subject_is_a_conflict() {
    let (app, _admin, bob, admin_id, message, _guard) = scene().await;
    let id = Uuid::now_v7();

    let filed = app
        .clone()
        .oneshot(post("/reports", &bob, report(&id, "message", &message)))
        .await
        .unwrap();
    assert_eq!(filed.status(), StatusCode::OK);
    let reused = app
        .oneshot(post("/reports", &bob, report(&id, "user", &admin_id)))
        .await
        .unwrap();
    assert_eq!(
        reused.status(),
        StatusCode::CONFLICT,
        "a reused id must never hand back a foreign report as if it were this one"
    );
}

#[tokio::test]
async fn a_second_open_report_about_the_same_subject_is_still_refused() {
    let (app, _admin, bob, _admin_id, message, _guard) = scene().await;

    let filed = app
        .clone()
        .oneshot(post(
            "/reports",
            &bob,
            report(&Uuid::now_v7(), "message", &message),
        ))
        .await
        .unwrap();
    assert_eq!(filed.status(), StatusCode::OK);
    let again = app
        .oneshot(post(
            "/reports",
            &bob,
            report(&Uuid::now_v7(), "message", &message),
        ))
        .await
        .unwrap();
    assert_eq!(
        again.status(),
        StatusCode::CONFLICT,
        "a fresh id is a new filing, and one open report per subject still holds"
    );
}

#[tokio::test]
async fn a_malformed_id_is_a_bad_request_and_a_missing_one_is_minted() {
    let (app, _admin, bob, _admin_id, message, _guard) = scene().await;

    let bad = app
        .clone()
        .oneshot(post(
            "/reports",
            &bob,
            json!({ "id": "not-a-uuid", "subject_kind": "message", "subject_id": message, "reason": "spam" }),
        ))
        .await
        .unwrap();
    assert_eq!(bad.status(), StatusCode::BAD_REQUEST);

    let minted = app
        .oneshot(post(
            "/reports",
            &bob,
            json!({ "subject_kind": "message", "subject_id": message, "reason": "spam" }),
        ))
        .await
        .unwrap();
    assert_eq!(
        minted.status(),
        StatusCode::OK,
        "older clients still file without an id"
    );
    assert!(Uuid::parse_str(json_body(minted).await["id"].as_str().unwrap()).is_ok());
}
