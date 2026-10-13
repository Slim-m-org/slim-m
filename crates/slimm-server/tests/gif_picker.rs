// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The full search-pick-select-send round trip against a fake GIF provider,
//! and the two-state shape the feature is built on: disabled by default, and
//! reachable only with `ATTACH_FILES`, the bit any other attachment already
//! needs.
//!
//! The fake server here plays both roles a real provider's own infrastructure
//! would: it answers `/v2/search` shaped exactly like Tenor's real API, and
//! its own search response embeds URLs pointing back at its own `/preview.gif`
//! and `/full.gif` routes - so a real end-to-end fetch happens for both the
//! thumbnail and the eventual attachment, through this server's proxy, with
//! nothing here ever reaching an actual Tenor endpoint.

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::routing::get;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::gifs::GifSearch;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::UserId;
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::RoleChanges;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-gif-picker-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn app(store: Store, gifs: GifSearch) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: Media::for_tests(),
        gifs,
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

/// The first account through here claims the deployment, which is what
/// grants `@everyone` (and so this account) `ATTACH_FILES`; see
/// `store::bootstrap::EVERYONE_DEFAULTS`.
async fn register(store: &Store, username: &str) -> (String, UserId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id)
}

fn req_get(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

fn post_json(uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A real, sniffable GIF: the six-byte magic number is all `sniff_content_type`
/// needs, plus arbitrary padding so preview and full are distinguishable by size.
fn gif_bytes(padding: usize) -> Vec<u8> {
    let mut bytes = b"GIF89a".to_vec();
    bytes.extend(std::iter::repeat_n(0u8, padding));
    bytes
}

/// A fake provider shaped exactly like Tenor's real `/v2/search`: its own
/// response embeds `preview.gif`/`full.gif` URLs pointing back at itself, so
/// `getGifPreview` and `selectGif` reach this same fake server rather than a
/// real CDN, proving the whole proxy chain rather than only the search leg.
/// The search handler needs the base URL to fill its own embedded links in,
/// so it is built with `State` rather than a `const` - the port is only
/// known once the listener is bound.
async fn search_with_base(State(base): State<String>) -> axum::Json<Value> {
    axum::Json(json!({
        "next": "",
        "results": [{
            "id": "fake-1",
            "content_description": "a cat waving",
            "media_formats": {
                "tinygif": {"url": format!("{base}/preview.gif"), "dims": [220, 165], "size": 1},
                "gif": {"url": format!("{base}/full.gif"), "dims": [498, 373], "size": 2}
            }
        }]
    }))
}

/// Tenor's own `/v2/featured` (trending) endpoint, shaped identically to
/// `/v2/search` but with a distinct title so a test can tell the two routes
/// apart by their response alone.
async fn trending_with_base(State(base): State<String>) -> axum::Json<Value> {
    axum::Json(json!({
        "next": "",
        "results": [{
            "id": "fake-trending-1",
            "content_description": "a trending waffle",
            "media_formats": {
                "tinygif": {"url": format!("{base}/preview.gif"), "dims": [220, 165], "size": 1},
                "gif": {"url": format!("{base}/full.gif"), "dims": [498, 373], "size": 2}
            }
        }]
    }))
}

async fn preview() -> Vec<u8> {
    gif_bytes(8)
}

async fn full() -> Vec<u8> {
    gif_bytes(64)
}

async fn spawn_fake_tenor() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let base = format!("http://{addr}");
    let router = Router::new()
        .route("/v2/search", get(search_with_base))
        .route("/v2/featured", get(trending_with_base))
        .route("/preview.gif", get(preview))
        .route("/full.gif", get(full))
        .with_state(base.clone());
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    base
}

#[tokio::test]
async fn search_preview_select_and_send_round_trip_through_the_fake_provider() {
    let tenor_base = spawn_fake_tenor().await;
    let gifs = GifSearch::for_test("tenor", &tenor_base, "test-key");

    let (store, _guard) = new_store().await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone(), gifs);
    let (token, _user_id) = register(&store, "alice").await;

    // Search.
    let search_response = app
        .clone()
        .oneshot(req_get("/gifs/search?q=cat", &token))
        .await
        .unwrap();
    assert_eq!(search_response.status(), StatusCode::OK);
    let search_body = json_body(search_response).await;
    let results = search_body["results"].as_array().expect("a results array");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["title"], "a cat waving");
    assert_eq!(results[0]["width"], 498);
    assert_eq!(results[0]["height"], 373);
    let gif_id = results[0]["id"]
        .as_str()
        .expect("an opaque token")
        .to_owned();
    // Never the provider's own id or a raw CDN URL; see gifs.rs's own doc comment.
    assert_ne!(gif_id, "fake-1");

    // Preview.
    let preview_response = app
        .clone()
        .oneshot(req_get(&format!("/gifs/preview/{gif_id}"), &token))
        .await
        .unwrap();
    assert_eq!(preview_response.status(), StatusCode::OK);
    assert_eq!(
        preview_response.headers().get("content-type").unwrap(),
        "image/gif"
    );

    // Select: downloads the full image and stores it as an ordinary attachment.
    let select_response = app
        .clone()
        .oneshot(post_json("/gifs/select", &token, json!({ "id": gif_id })))
        .await
        .unwrap();
    assert_eq!(select_response.status(), StatusCode::CREATED);
    let attachment = json_body(select_response).await;
    assert_eq!(attachment["content_type"], "image/gif");
    assert_eq!(attachment["size"], gif_bytes(64).len());
    // Named after the provider's title, not a bare "gif.gif", so a saved GIF is findable later.
    assert_eq!(attachment["filename"], "a_cat_waving.gif");
    let attachment_id = attachment["id"].as_str().unwrap().to_owned();

    // Send: the id from `selectGif` is an ordinary attachment id, usable exactly like one from `uploadAttachment`.
    let send_response = app
        .clone()
        .oneshot(post_json(
            &format!("/channels/{}/messages", channel.id),
            &token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "",
                "attachment_ids": [attachment_id.clone()],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(send_response.status(), StatusCode::OK);
    let message = json_body(send_response).await;
    let sent_attachments = message["attachments"].as_array().unwrap();
    assert_eq!(sent_attachments.len(), 1);
    assert_eq!(sent_attachments[0]["id"], attachment_id);

    // Fetching it back is an ordinary, already-self-hosted attachment fetch.
    let fetched = app
        .clone()
        .oneshot(req_get(&format!("/attachments/{attachment_id}"), &token))
        .await
        .unwrap();
    assert_eq!(fetched.status(), StatusCode::OK);
}

/// The picker's default content before a member types anything: a distinct
/// endpoint from `search`, proxied and tokenized exactly the same way -
/// never the provider's own id or a raw CDN URL, and its preview streams
/// through this server precisely like a search result's does.
#[tokio::test]
async fn trending_returns_results_through_the_fake_provider_and_mints_a_token() {
    let tenor_base = spawn_fake_tenor().await;
    let gifs = GifSearch::for_test("tenor", &tenor_base, "test-key");

    let (store, _guard) = new_store().await;
    let app = app(store.clone(), gifs);
    let (token, _user_id) = register(&store, "alice").await;

    let trending_response = app
        .clone()
        .oneshot(req_get("/gifs/trending", &token))
        .await
        .unwrap();
    assert_eq!(trending_response.status(), StatusCode::OK);
    let body = json_body(trending_response).await;
    let results = body["results"].as_array().expect("a results array");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["title"], "a trending waffle");
    let gif_id = results[0]["id"]
        .as_str()
        .expect("an opaque token")
        .to_owned();
    assert_ne!(gif_id, "fake-trending-1");

    let preview_response = app
        .clone()
        .oneshot(req_get(&format!("/gifs/preview/{gif_id}"), &token))
        .await
        .unwrap();
    assert_eq!(preview_response.status(), StatusCode::OK);
}

#[tokio::test]
async fn with_no_provider_configured_every_route_answers_not_implemented() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone(), GifSearch::disabled());
    let (token, _user_id) = register(&store, "alice").await;

    let search_response = app
        .clone()
        .oneshot(req_get("/gifs/search?q=cat", &token))
        .await
        .unwrap();
    assert_eq!(search_response.status(), StatusCode::NOT_IMPLEMENTED);

    let trending_response = app
        .clone()
        .oneshot(req_get("/gifs/trending", &token))
        .await
        .unwrap();
    assert_eq!(trending_response.status(), StatusCode::NOT_IMPLEMENTED);

    let preview_response = app
        .clone()
        .oneshot(req_get("/gifs/preview/anything", &token))
        .await
        .unwrap();
    assert_eq!(preview_response.status(), StatusCode::NOT_IMPLEMENTED);

    let select_response = app
        .clone()
        .oneshot(post_json(
            "/gifs/select",
            &token,
            json!({ "id": "anything" }),
        ))
        .await
        .unwrap();
    assert_eq!(select_response.status(), StatusCode::NOT_IMPLEMENTED);
}

/// A GIF search is a way to end up with an attachment, so it needs the same
/// bit an ordinary upload does - denied here by revoking it from `@everyone`
/// and never granting it back, rather than a channel overwrite, since the
/// permission is deployment-wide.
#[tokio::test]
async fn without_attach_files_the_route_is_forbidden_even_with_a_provider_configured() {
    let tenor_base = spawn_fake_tenor().await;
    let gifs = GifSearch::for_test("tenor", &tenor_base, "test-key");

    let (store, _guard) = new_store().await;
    let app = app(store.clone(), gifs);
    // The first account claims the deployment as admin, whose ADMINISTRATOR bit bypasses this check.
    let _admin = register(&store, "admin").await;
    let (token, _user_id) = register(&store, "alice").await;
    // ATTACH_FILES is deployment-wide, so it is removed from `@everyone` directly.
    let everyone = store.list_roles().await.unwrap();
    let everyone_role = everyone.iter().find(|r| r.is_everyone).unwrap();
    store
        .update_role(
            everyone_role.id,
            RoleChanges {
                permissions: Some(Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES)),
                ..RoleChanges::default()
            },
        )
        .await
        .unwrap();

    let search_response = app
        .clone()
        .oneshot(req_get("/gifs/search?q=cat", &token))
        .await
        .unwrap();
    assert_eq!(search_response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn an_empty_or_over_long_query_is_refused_before_any_provider_call() {
    let tenor_base = spawn_fake_tenor().await;
    let gifs = GifSearch::for_test("tenor", &tenor_base, "test-key");
    let (store, _guard) = new_store().await;
    let app = app(store.clone(), gifs);
    let (token, _user_id) = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(req_get("/gifs/search?q=", &token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let too_long = format!("/gifs/search?q={}", "a".repeat(201));
    let response = app
        .clone()
        .oneshot(req_get(&too_long, &token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let at_cap = format!("/gifs/search?q={}", "a".repeat(200));
    let response = app.clone().oneshot(req_get(&at_cap, &token)).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

/// A token this server no longer holds is the caller's results having gone
/// stale, not the provider being down, and the two need telling apart: a
/// stale token never works again however many times it is retried, and only
/// a fresh search mints one that does.
///
/// The case is not hypothetical. The cache is in-process, so every restart
/// empties it - and this deployment restarts on each merge to main - leaving
/// an open picker whose every tile is already dead.
#[tokio::test]
async fn an_unknown_token_reads_as_expired_rather_than_unavailable() {
    let tenor_base = spawn_fake_tenor().await;
    let gifs = GifSearch::for_test("tenor", &tenor_base, "test-key");
    let (store, _guard) = new_store().await;
    let app = app(store.clone(), gifs);
    let (token, _user) = register(&store, "root").await;

    // Never minted by any search: the shape an expired or evicted one has.
    let response = app
        .oneshot(post_json(
            "/gifs/select",
            &token,
            json!({ "id": "01a00000-0000-7000-8000-000000000000" }),
        ))
        .await
        .unwrap();

    assert_eq!(
        response.status(),
        StatusCode::NOT_FOUND,
        "503 would tell a client to retry the same dead pick forever"
    );
    let body = json_body(response).await;
    assert!(
        body["error"]
            .as_str()
            .unwrap_or_default()
            .contains("search again"),
        "the message has to name the one thing that fixes it, got {body:?}"
    );
}
