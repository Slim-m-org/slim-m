// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! HTTP-layer tests for `POST /emoji/bulk`, split from `emoji_http.rs` to
//! keep that file under the review budget.
//!
//! The single upload's own suite already pins MANAGE_SERVER gating, bad-id
//! handling and the served-image headers; what this file owns is what is
//! specific to the bulk shape: one request creates several emoji charged
//! once against `Class::Upload` rather than once per image (the defect a
//! 200-image pack hit in the field), a batch over the per-request cap
//! refuses rather than truncating, an invalid image anywhere in the batch
//! leaves none of it written, and a name collision - within the batch or
//! against an existing emoji - answers the same way the single upload does.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::emoji::bulk::MAX_BULK_IMAGES;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::media::Media;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-emoji-bulk-http");
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
        media: Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

/// A member with a session, straight through the store. The first caller
/// bootstraps the deployment and becomes the admin, exactly as
/// `emoji_http.rs`'s own `register` does.
async fn register(store: &Store, username: &str) -> String {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

/// A PNG the sniffer accepts, varied by `filler` so two images with
/// different names never collide on content.
fn png(filler: &[u8]) -> Vec<u8> {
    let mut bytes = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    bytes.extend_from_slice(filler);
    bytes
}

fn bulk_body(images: &[(&str, Vec<u8>)]) -> Value {
    json!({
        "images": images
            .iter()
            .map(|(name, bytes)| json!({"name": name, "data": BASE64.encode(bytes)}))
            .collect::<Vec<_>>(),
    })
}

fn request_json(method: &str, uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_vec(&body).unwrap()))
        .unwrap()
}

fn request_bytes(method: &str, uri: &str, token: &str, body: Vec<u8>) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from(body))
        .unwrap()
}

async fn bulk_upload(
    app: &Router,
    token: &str,
    images: &[(&str, Vec<u8>)],
) -> axum::response::Response {
    app.clone()
        .oneshot(request_json(
            "POST",
            "/emoji/bulk",
            token,
            bulk_body(images),
        ))
        .await
        .unwrap()
}

async fn single_upload(
    app: &Router,
    token: &str,
    name: &str,
    body: Vec<u8>,
) -> axum::response::Response {
    app.clone()
        .oneshot(request_bytes(
            "POST",
            &format!("/emoji?name={name}"),
            token,
            body,
        ))
        .await
        .unwrap()
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

async fn emoji_count(app: &Router, token: &str) -> usize {
    let listed = json_body(
        app.clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/emoji")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap(),
    )
    .await;
    listed.as_array().unwrap().len()
}

/// A bulk request creates every image it names, and - the actual defect a
/// 200-image pack hit - the whole call costs exactly one charge against
/// `Class::Upload`, not one per image. `Class::Upload`'s burst is 10: this
/// batch of 20 would have burned the entire budget after the tenth image
/// under the old per-image charge, refusing the rest with 429. Spending nine
/// more single-image charges afterward and still succeeding proves the batch
/// itself only spent one.
#[tokio::test]
async fn bulk_upload_charges_the_rate_limit_once_for_the_whole_batch() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;

    let images: Vec<(&str, Vec<u8>)> = (0..20)
        .map(|i| {
            let name: &'static str = Box::leak(format!("bulk{i}").into_boxed_str());
            (name, png(&[i as u8]))
        })
        .collect();

    let created = bulk_upload(&app, &admin, &images).await;
    assert_eq!(created.status(), StatusCode::CREATED);
    let body = json_body(created).await;
    assert_eq!(body.as_array().unwrap().len(), 20);
    assert_eq!(emoji_count(&app, &admin).await, 20);

    for i in 0..9 {
        let response = single_upload(&app, &admin, &format!("single{i}"), png(&[100 + i])).await;
        assert_eq!(
            response.status(),
            StatusCode::CREATED,
            "request {i} is within the 10-request burst: 1 for the bulk call, 9 here"
        );
    }

    let over_budget = single_upload(&app, &admin, "one_too_many", png(&[200])).await;
    assert_eq!(
        over_budget.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "the tenth single upload is the eleventh charge, past the burst of 10"
    );
}

/// More images than the per-request cap is a 400, and nothing from the
/// oversized batch is written - never silently truncated to the first
/// `MAX_BULK_IMAGES`.
#[tokio::test]
async fn bulk_upload_over_the_cap_is_bad_request_not_truncated() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;

    let images: Vec<(&str, Vec<u8>)> = (0..=MAX_BULK_IMAGES)
        .map(|i| {
            let name: &'static str = Box::leak(format!("e{i}").into_boxed_str());
            (name, png(&[i as u8]))
        })
        .collect();
    assert_eq!(images.len(), MAX_BULK_IMAGES + 1);

    let response = bulk_upload(&app, &admin, &images).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        emoji_count(&app, &admin).await,
        0,
        "an over-cap batch is refused whole, not truncated to what would have fit"
    );
}

/// One invalid image in an otherwise-valid batch refuses the whole request,
/// and the images that would have been fine on their own are not written
/// either - validate-all-then-write, the same rule `bulk_delete_messages`
/// keeps for message ids.
#[tokio::test]
async fn an_invalid_image_in_the_batch_leaves_no_earlier_image_written() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;

    let images: Vec<(&str, Vec<u8>)> = vec![
        ("first", png(b"first")),
        ("second", png(b"second")),
        ("third", png(b"third")),
        ("not_an_image", b"this is plainly not an image".to_vec()),
    ];

    let response = bulk_upload(&app, &admin, &images).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        emoji_count(&app, &admin).await,
        0,
        "first, second and third were valid on their own but must not be \
         written while the batch as a whole is refused"
    );
}

/// The refusal still covers the whole batch, but it names the image at fault
/// so an admin retrying a 50-image chunk can tell which file to fix.
#[tokio::test]
async fn a_refused_batch_names_the_image_that_broke_it() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;

    let images: Vec<(&str, Vec<u8>)> = vec![
        ("first", png(b"first")),
        ("junk_file", b"this is plainly not an image".to_vec()),
    ];
    let response = bulk_upload(&app, &admin, &images).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let message = json_body(response).await["error"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(message.contains("image 2"), "{message}");
    assert!(message.contains("junk_file"), "{message}");
    assert!(message.contains("unsupported emoji type"), "{message}");

    let images: Vec<(&str, Vec<u8>)> =
        vec![("party_parrot", png(b"one")), ("Party-Parrot", png(b"two"))];
    let response = bulk_upload(&app, &admin, &images).await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let message = json_body(response).await["error"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(message.contains("image 2"), "{message}");
    assert!(message.contains("Party-Parrot"), "{message}");
}

/// Two images in the same batch sharing a normalised name is the same
/// refusal the single path gives for uploading a taken name twice: a
/// conflict, with nothing from the batch written.
#[tokio::test]
async fn a_duplicate_name_within_the_batch_is_a_conflict_like_the_single_path() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;

    let images: Vec<(&str, Vec<u8>)> =
        vec![("party_parrot", png(b"one")), ("Party-Parrot", png(b"two"))];

    let response = bulk_upload(&app, &admin, &images).await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    assert_eq!(
        emoji_count(&app, &admin).await,
        0,
        "neither half of the colliding pair is written"
    );
}

/// A batch naming an emoji that already exists is refused the same way a
/// single re-upload of that name is: a conflict, and the deployment's
/// existing emoji is left exactly as it was.
#[tokio::test]
async fn a_name_already_taken_is_a_conflict_like_the_single_path() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;

    let existing = single_upload(&app, &admin, "taken", png(b"existing")).await;
    assert_eq!(existing.status(), StatusCode::CREATED);

    let images: Vec<(&str, Vec<u8>)> = vec![("fresh", png(b"fresh")), ("taken", png(b"new"))];
    let response = bulk_upload(&app, &admin, &images).await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    assert_eq!(
        emoji_count(&app, &admin).await,
        1,
        "the pre-existing emoji is untouched and 'fresh' was never written"
    );
}

/// Bulk creation takes MANAGE_SERVER exactly like the single upload does.
#[tokio::test]
async fn bulk_upload_requires_manage_server() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let _admin = register(&store, "admin").await;
    let member = register(&store, "member").await;

    let response = bulk_upload(&app, &member, &[("party_parrot", png(b"x"))]).await;
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert_eq!(emoji_count(&app, &member).await, 0);
}
