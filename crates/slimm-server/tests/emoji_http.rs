// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! HTTP-layer integration tests for custom emoji, driving the real handlers in
//! `http/emoji.rs` rather than the shared domain logic in `crate::emoji`.
//!
//! The refusal atomicity (`emoji_refusal.rs`) and name/collision rules
//! (`emoji_import/`) are already pinned at the store layer, and the response
//! contract drives one happy path for shape only. What none of those exercise
//! is the HTTP contract this module actually owns: that writes are gated on
//! MANAGE_SERVER while reads are open to any member, that a bad id is a 400 and
//! a missing one is handled without leaking, and that a served image carries
//! the immutable cache header. Those are the cases below.
//!
//! A note on setup: unlike the reaction and avatar suites, these tests do NOT
//! pre-create the `everyone` role, so the first `register` runs a real
//! `bootstrap_deployment` and grants that account the admin role
//! (ADMINISTRATOR, which the evaluator expands to every permission, MANAGE_SERVER
//! included). A second `register` finds the deployment already claimed and is
//! left an ordinary member. That is the manager/non-manager pair every test
//! here needs.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::media::Media;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-emoji-http");
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

fn request_bytes(method: &str, uri: &str, token: &str, body: Vec<u8>) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from(body))
        .unwrap()
}

fn request_plain(method: &str, uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method(method)
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

/// A member with a session, straight through the store. The first caller
/// bootstraps the deployment and so becomes the admin; see the module doc.
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

/// A small PNG, the same shape the response contract uses for emoji.
fn png() -> Vec<u8> {
    support::images::small_png()
}

async fn upload(app: &Router, token: &str, name: &str, body: Vec<u8>) -> axum::response::Response {
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

/// Writes are MANAGE_SERVER only; an ordinary member is refused, and the
/// refusal is a real no-op rather than a soft failure the caller could ignore.
#[tokio::test]
async fn writes_require_manage_server() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;
    let member = register(&store, "member").await;

    let created = upload(&app, &admin, "party_parrot", png()).await;
    assert_eq!(created.status(), StatusCode::CREATED);
    let id = json_body(created).await["id"].as_str().unwrap().to_owned();

    let member_upload = upload(&app, &member, "member_made", png()).await;
    assert_eq!(
        member_upload.status(),
        StatusCode::FORBIDDEN,
        "a member without MANAGE_SERVER cannot add an emoji"
    );

    let member_delete = app
        .clone()
        .oneshot(request_plain("DELETE", &format!("/emoji/{id}"), &member))
        .await
        .unwrap();
    assert_eq!(
        member_delete.status(),
        StatusCode::FORBIDDEN,
        "a member without MANAGE_SERVER cannot delete an emoji"
    );

    // The refused delete left the emoji in place: exactly the admin's one.
    let listed = json_body(
        app.clone()
            .oneshot(request_plain("GET", "/emoji", &admin))
            .await
            .unwrap(),
    )
    .await;
    let names: Vec<&str> = listed
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["party_parrot"]);
}

/// Listing and image bytes are open to any authenticated member, and a served
/// image is content-addressed, so it carries the immutable cache header.
#[tokio::test]
async fn reads_are_open_to_every_member() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;
    let member = register(&store, "member").await;

    let id = json_body(upload(&app, &admin, "party_parrot", png()).await).await["id"]
        .as_str()
        .unwrap()
        .to_owned();

    let listed = json_body(
        app.clone()
            .oneshot(request_plain("GET", "/emoji", &member))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["name"], "party_parrot");

    let image = app
        .clone()
        .oneshot(request_plain("GET", &format!("/emoji/{id}/image"), &member))
        .await
        .unwrap();
    assert_eq!(image.status(), StatusCode::OK);
    assert_eq!(image.headers().get("content-type").unwrap(), "image/png");
    assert_eq!(
        image.headers().get("cache-control").unwrap(),
        "private, max-age=31536000, immutable",
        "an emoji's bytes never change under its id, so it caches forever"
    );
}

/// Two emoji cannot share a name, because a message between colons has to name
/// exactly one image.
#[tokio::test]
async fn a_duplicate_name_is_a_conflict() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;

    let first = upload(&app, &admin, "party_parrot", png()).await;
    assert_eq!(first.status(), StatusCode::CREATED);

    let second = upload(&app, &admin, "party_parrot", png()).await;
    assert_eq!(second.status(), StatusCode::CONFLICT);
}

/// The same name in another case or spacing is still the same name.
#[tokio::test]
async fn a_duplicate_name_in_another_spelling_is_a_conflict() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;

    assert_eq!(
        upload(&app, &admin, "party_parrot", png()).await.status(),
        StatusCode::CREATED
    );
    let again = upload(&app, &admin, "Party%20Parrot", png()).await;
    assert_eq!(again.status(), StatusCode::CONFLICT);
}

/// A custom `:bug:` would hide the standard bug emoji, so the name is refused.
#[tokio::test]
async fn a_standard_shortcode_is_refused() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;

    let response = upload(&app, &admin, "Bug", png()).await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = json_body(response).await;
    assert!(body["error"].as_str().unwrap().contains("standard emoji"));
}

/// Identical bytes under a second name are allowed and reported.
#[tokio::test]
async fn identical_bytes_under_a_new_name_are_reported_not_blocked() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;

    let first = json_body(upload(&app, &admin, "parrot_a", png()).await).await;
    assert!(first.get("same_image_as").is_none());
    let second = upload(&app, &admin, "parrot_two", png()).await;
    assert_eq!(second.status(), StatusCode::CREATED);
    assert_eq!(json_body(second).await["same_image_as"], "parrot_a");
}

/// An unusable name and a file that is not an image are both the caller's
/// fault, so both are 400 rather than anything a retry would fix.
#[tokio::test]
async fn an_unusable_name_and_a_non_image_are_bad_requests() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;

    // 40 characters is over the 32-character ceiling the name rule allows.
    let long_name = "a".repeat(40);
    let bad_name = upload(&app, &admin, &long_name, png()).await;
    assert_eq!(bad_name.status(), StatusCode::BAD_REQUEST);

    let not_an_image = upload(
        &app,
        &admin,
        "not_a_picture",
        b"this is plainly not an image".to_vec(),
    )
    .await;
    assert_eq!(not_an_image.status(), StatusCode::BAD_REQUEST);
}

/// A malformed id is a 400 on either id-taking route; a well-formed id that
/// names nothing is a 404 to fetch and, so a retry need not tell "gone" from
/// "never was", a 204 to delete.
#[tokio::test]
async fn a_malformed_id_is_bad_request_a_missing_one_is_handled() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;

    let bad_image = app
        .clone()
        .oneshot(request_plain("GET", "/emoji/not-a-uuid/image", &admin))
        .await
        .unwrap();
    assert_eq!(bad_image.status(), StatusCode::BAD_REQUEST);

    let bad_delete = app
        .clone()
        .oneshot(request_plain("DELETE", "/emoji/not-a-uuid", &admin))
        .await
        .unwrap();
    assert_eq!(bad_delete.status(), StatusCode::BAD_REQUEST);

    let absent = Uuid::now_v7();
    let missing_image = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/emoji/{absent}/image"),
            &admin,
        ))
        .await
        .unwrap();
    assert_eq!(missing_image.status(), StatusCode::NOT_FOUND);

    let missing_delete = app
        .clone()
        .oneshot(request_plain("DELETE", &format!("/emoji/{absent}"), &admin))
        .await
        .unwrap();
    assert_eq!(
        missing_delete.status(),
        StatusCode::NO_CONTENT,
        "deleting an emoji that is already gone is idempotent"
    );
}
