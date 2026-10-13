// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Placing an `image` object over HTTP: the one kind-specific field this
//! route reads out of an otherwise opaque `props`, and what it authorizes
//! against - the same `may_link` check a message's own attachment already
//! passes through, so pasting bytes onto a canvas reaches no further than
//! sending them ever could.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::media::Media;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
use slimm_server::voice::VoiceService;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

async fn new_store_and_pool() -> (Store, sqlx::SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-canvas-image");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

fn app(store: Store) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: VoiceService::disabled(),
        media: Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

async fn register(store: &Store, username: &str) -> (String, UserId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id)
}

async fn general(store: &Store) -> ChannelId {
    store.list_channels().await.unwrap()[0].id
}

fn id() -> String {
    Uuid::now_v7().to_string()
}

/// A minimal, validly-sniffable PNG: only the 8-byte magic number matters to
/// the server's allowlist.
const PNG: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

async fn post_json(app: &Router, uri: &str, token: &str, body: Value) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(uri)
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_vec(&body).unwrap()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn upload(app: &Router, token: &str) -> String {
    upload_named(app, token, "pasted.png", PNG.to_vec()).await
}

async fn upload_named(app: &Router, token: &str, filename: &str, bytes: Vec<u8>) -> String {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/attachments?filename={filename}"))
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(bytes))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    body["id"].as_str().unwrap().to_owned()
}

fn image(attachment: &str) -> Value {
    json!({
        "id": id(),
        "kind": "image",
        "x": 0.0, "y": 0.0, "w": 64.0, "h": 64.0,
        "props": { "attachment": attachment, "content_type": "image/png" },
    })
}

#[tokio::test]
async fn a_caller_who_uploaded_the_attachment_may_place_it() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);

    let attachment = upload(&app, &token).await;
    let (status, body) = post_json(
        &app,
        &format!("/channels/{channel}/canvas/objects"),
        &token,
        image(&attachment),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["kind"], "image");
}

#[tokio::test]
async fn an_attachment_never_uploaded_is_a_bad_request() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);

    let never_uploaded = "aa".repeat(32);
    let (status, body) = post_json(
        &app,
        &format!("/channels/{channel}/canvas/objects"),
        &token,
        image(&never_uploaded),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
}

/// The same collapse `SendError::AttachmentNotFound` already makes for a
/// message: "uploaded by someone else, and not visible to me anywhere" is
/// indistinguishable from "never existed", so this is a 400, never a 403 that
/// would confirm the hash is real.
#[tokio::test]
async fn an_attachment_uploaded_by_someone_else_and_never_seen_is_refused() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (root_token, _root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob_token, _bob_id) = register(&store, "bob").await;

    let attachment = upload(&app, &root_token).await;
    let (status, body) = post_json(
        &app,
        &format!("/channels/{channel}/canvas/objects"),
        &bob_token,
        image(&attachment),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "bob never uploaded it and has not seen it anywhere: {body}"
    );
}

/// The reach a message's own attachment check already grants: bytes visible
/// to a caller in any channel may be forwarded, including onto a canvas.
#[tokio::test]
async fn an_attachment_already_visible_in_a_message_may_be_placed_by_anyone_who_can_view_it() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (root_token, root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob_token, _bob_id) = register(&store, "bob").await;

    let attachment = upload(&app, &root_token).await;
    store
        .send_message(NewMessage {
            channel_id: channel,
            author_id: root_id,
            id: slimm_server::ids::MessageId::generate(),
            content: "look",
            attachment_ids: &[slimm_server::media::from_hex(&attachment).unwrap()],
            reply_to_id: None,
            forward: None,
        })
        .await
        .expect("root can send with their own upload");

    let (status, body) = post_json(
        &app,
        &format!("/channels/{channel}/canvas/objects"),
        &bob_token,
        image(&attachment),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::CREATED,
        "bob can already see the attachment via the message: {body}"
    );
}

#[tokio::test]
async fn a_missing_or_malformed_attachment_field_is_a_bad_request() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);

    let missing = json!({
        "id": id(), "kind": "image",
        "x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0,
        "props": { "content_type": "image/png" },
    });
    let (status, _) = post_json(
        &app,
        &format!("/channels/{channel}/canvas/objects"),
        &token,
        missing,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "no attachment field at all"
    );

    let malformed = json!({
        "id": id(), "kind": "image",
        "x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0,
        "props": { "attachment": "not-hex-at-all" },
    });
    let (status, _) = post_json(
        &app,
        &format!("/channels/{channel}/canvas/objects"),
        &token,
        malformed,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "not a valid hex sha256");
}

/// Placing an image is what makes it fetchable to anyone else who can view
/// the channel - the whole point of `canvas_object_attachments` existing.
#[tokio::test]
async fn placing_an_image_makes_it_fetchable_by_another_viewer() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (root_token, _root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob_token, _bob_id) = register(&store, "bob").await;

    let attachment = upload(&app, &root_token).await;
    let (status, body) = post_json(
        &app,
        &format!("/channels/{channel}/canvas/objects"),
        &root_token,
        image(&attachment),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");

    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/attachments/{attachment}"))
                .header("authorization", format!("Bearer {bob_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "bob can view the channel, so he can fetch the pasted image's bytes"
    );
}

#[tokio::test]
async fn an_attachment_that_is_not_a_picture_cannot_be_placed_as_an_image() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);

    let pdf = upload_named(&app, &token, "notes.pdf", b"%PDF-1.7\n%%EOF\n".to_vec()).await;
    let (status, body) = post_json(
        &app,
        &format!("/channels/{channel}/canvas/objects"),
        &token,
        image(&pdf),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(
        body["error"],
        "an image object must name a picture attachment"
    );
}
