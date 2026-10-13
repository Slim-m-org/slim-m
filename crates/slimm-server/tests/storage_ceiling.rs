// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The deployment-wide storage ceiling, and the length cap on a moderation
//! reason.
//!
//! Both are finding 13 and 16 of the 2026-07-30 audit, and both are about a
//! bound existing at all rather than about anybody being kept out: the upload
//! path needs ATTACH_FILES and the moderation verbs need KICK_MEMBERS or
//! BAN_MEMBERS. What the upload path had no bound on was the volume, which
//! `deploy/README.md` already tells an operator Litestream does not back up, so
//! disk is the exposed resource and nothing reported on it.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::UserId;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

mod support;

/// A one-pixel PNG, so `sniff_content_type` accepts it. The trailing bytes are
/// varied per call to make each upload a different hash.
fn png(tag: u8) -> Vec<u8> {
    let mut bytes = support::images::small_png();
    bytes.extend(std::iter::repeat_n(tag, 240));
    bytes
}

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

fn app(store: Store, ceiling: Option<u64>) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests().with_total_ceiling(ceiling),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

async fn admin(store: &Store, username: &str) -> (UserId, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (account.id, token)
}

fn upload(token: &str, bytes: Vec<u8>) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/attachments?filename=shot.png")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/octet-stream")
        .body(Body::from(bytes))
        .unwrap()
}

/// Past the ceiling an upload is refused, and refused with a status that says
/// which side the problem is on: 507, not the 413 an over-large single file
/// gets. An operator reading a screenshot needs to tell "make it smaller" from
/// "the volume is full", because only one of those is theirs to fix.
#[tokio::test]
async fn an_upload_past_the_deployment_ceiling_is_refused_as_out_of_storage() {
    let (store, _guard) = new_store("slimm-ceiling-refuse").await;
    let (_admin, token) = admin(&store, "root").await;
    let first = png(1);
    let ceiling = first.len() as u64 + 10;
    let app = app(store.clone(), Some(ceiling));

    let response = app.clone().oneshot(upload(&token, first)).await.unwrap();
    assert_eq!(response.status(), StatusCode::CREATED, "the first one fits");

    let response = app.oneshot(upload(&token, png(2))).await.unwrap();
    assert_eq!(
        response.status(),
        StatusCode::INSUFFICIENT_STORAGE,
        "the second takes it past the ceiling"
    );
}

/// The refusal happens before the bytes are written, so nothing is left on disk
/// for the sweep to reclaim. Asserted through the store rather than the
/// filesystem: a row is what a later fetch or the sweep would find.
#[tokio::test]
async fn a_refused_upload_stores_nothing() {
    let (store, _guard) = new_store("slimm-ceiling-nothing").await;
    let (_admin, token) = admin(&store, "root").await;
    let app = app(store.clone(), Some(1));

    let response = app.oneshot(upload(&token, png(3))).await.unwrap();
    assert_eq!(response.status(), StatusCode::INSUFFICIENT_STORAGE);
    assert_eq!(
        store.total_attachment_bytes().await.unwrap(),
        0,
        "a refusal must not leave a row, or the ceiling holds itself shut"
    );
}

/// No ceiling configured is no ceiling, which is what every existing deployment
/// gets on upgrade: the right number is the operator's disk, not ours.
#[tokio::test]
async fn no_ceiling_configured_refuses_nothing() {
    let (store, _guard) = new_store("slimm-ceiling-absent").await;
    let (_admin, token) = admin(&store, "root").await;
    let app = app(store.clone(), None);

    for tag in 1..=3u8 {
        let response = app.clone().oneshot(upload(&token, png(tag))).await.unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
    }
    assert!(store.total_attachment_bytes().await.unwrap() > 0);
}

/// Custom emoji are rows in the same table and count toward the same ceiling.
/// They are bounded in count anyway (500, behind MANAGE_SERVER), so this is
/// consistency rather than a hole being closed - but a ceiling one upload path
/// ignores is not a ceiling.
#[tokio::test]
async fn a_custom_emoji_upload_counts_against_the_ceiling_too() {
    let (store, _guard) = new_store("slimm-ceiling-emoji").await;
    let (_admin, token) = admin(&store, "root").await;
    let app = app(store.clone(), Some(1));

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/emoji?name=wave")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/octet-stream")
                .body(Body::from(png(4)))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::INSUFFICIENT_STORAGE);
}

// --- Moderation reason length ---

async fn moderate(app: &Router, uri: &str, token: &str, reason: &str) -> StatusCode {
    app.clone()
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(uri)
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "duration_seconds": 600, "reason": reason }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap()
        .status()
}

/// A timeout and a removal reason are capped at the same 2000 the report reason
/// always was. `GET /members/removed` hands a removal reason back verbatim for
/// every removal in force, so its length is a contract a client rendering that
/// list can design against, and the only bound before this was the module's
/// 4 KiB body limit.
#[tokio::test]
async fn a_moderation_reason_is_capped_at_the_same_length_as_a_report_reason() {
    let (store, _guard) = new_store("slimm-reason-cap").await;
    let (_admin, token) = admin(&store, "root").await;
    let target = store.create_user("bob", "Bob").await.unwrap();
    let app = app(store.clone(), None);

    let long = "x".repeat(2001);
    let timeout_uri = format!("/members/{}/timeout", target.id);
    assert_eq!(
        moderate(&app, &timeout_uri, &token, &long).await,
        StatusCode::BAD_REQUEST,
        "2001 characters is over the cap"
    );

    let at_the_cap = "x".repeat(2000);
    assert_eq!(
        moderate(&app, &timeout_uri, &token, &at_the_cap).await,
        StatusCode::OK,
        "the cap itself is allowed, or it is really 1999"
    );
}

/// A reason stays optional on the moderation verbs, unlike on a report. Capping
/// a field is not an excuse to start requiring it.
#[tokio::test]
async fn a_moderation_reason_is_still_optional() {
    let (store, _guard) = new_store("slimm-reason-optional").await;
    let (_admin, token) = admin(&store, "root").await;
    let target = store.create_user("bob", "Bob").await.unwrap();
    let app = app(store.clone(), None);

    let response = app
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(format!("/members/{}/timeout", target.id))
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({ "duration_seconds": 600 }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let held = store.member_timeout(target.id).await.unwrap();
    assert!(held.is_some(), "the timeout applied with no reason given");
}

/// The report reason's own 2000-character cap, which had no test before the
/// validator became shared: removing the length check killed only the
/// moderation-verb test above, so the cap that had been there all along was
/// resting on nothing.
#[tokio::test]
async fn a_report_reason_is_capped_too() {
    let (store, _guard) = new_store("slimm-reason-report").await;
    let (author, _admin_token) = admin(&store, "root").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let message = store
        .send_message(NewMessage::plain(
            channel,
            author,
            slimm_server::ids::MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap()
        .message
        .id;
    let app = app(store.clone(), None);
    let reporter = store.create_user("reporter", "reporter").await.unwrap();
    let token = store
        .open_session(reporter.id, "cli")
        .await
        .unwrap()
        .access_token;

    let file = |reason: String| {
        let app = app.clone();
        let token = token.clone();
        async move {
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/reports")
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "subject_kind": "message",
                            "subject_id": message.to_string(),
                            "reason": reason,
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap()
            .status()
        }
    };

    assert_eq!(file("x".repeat(2001)).await, StatusCode::BAD_REQUEST);
    assert_eq!(
        file(String::new()).await,
        StatusCode::BAD_REQUEST,
        "a report must still say why, unlike a moderation verb"
    );
    assert_eq!(file("x".repeat(2000)).await, StatusCode::OK);
}
