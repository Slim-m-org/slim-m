// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The canvas inside a DM: the owner asked for one so two people can work
//! through something 1-on-1 without needing a voice channel for it,
//! superseding the earlier "no canvas outside voice channels" call, which
//! had also read as excluding DMs. `DM_BASE` now grants `USE_CANVAS`, and
//! `BLOCKED_DENY` removes it, mirroring how a block already refuses sending
//! (`dms.rs`) without erasing what already exists. The canvas routes carry
//! no channel-kind check of their own, so a DM participant placing an object
//! should succeed exactly as it does in an ordinary channel, and a blocked
//! pair should be refused exactly as they already are for messages.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
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

fn request(method: &str, uri: &str, token: Option<&str>, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A member with a session, built straight through the store; see
/// `dms.rs`'s own copy of this helper for why not `/auth/register`.
async fn register(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

async fn open_dm(app: &Router, token: &str, target_id: &str) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/dms/{target_id}"),
            Some(token),
            None,
        ))
        .await
        .unwrap();
    let status = response.status();
    (status, json_body(response).await)
}

async fn block(app: &Router, token: &str, target_id: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/blocks/{target_id}"),
            Some(token),
            None,
        ))
        .await
        .unwrap()
        .status()
}

fn stroke() -> Value {
    json!({
        "id": Uuid::now_v7().to_string(),
        "kind": "stroke",
        "x": 10.0, "y": 20.0, "w": 30.0, "h": 40.0,
        "props": { "points": [0.0, 0.0, 30.0, 40.0], "width": 3.0, "color": "annotation" },
    })
}

async fn place_object(app: &Router, channel_id: &str, token: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/canvas/objects"),
            Some(token),
            Some(stroke()),
        ))
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn a_dm_participant_can_use_the_canvas() {
    let (store, _guard) = support::new_store("slimm-dm-canvas-test").await;
    let app = app(store.clone());

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    let (status, opened) = open_dm(&app, &alice_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);
    let channel_id = opened["channel_id"].as_str().unwrap().to_owned();

    assert_eq!(
        place_object(&app, &channel_id, &alice_token).await,
        StatusCode::CREATED,
        "a DM participant must be able to place a canvas object"
    );
    assert_eq!(
        place_object(&app, &channel_id, &bob_token).await,
        StatusCode::CREATED,
        "the other participant must be able to as well"
    );
}

/// `USE_CANVAS` is one of the bits `BLOCKED_DENY` removes: a blocked pair
/// must not be able to draw on the shared canvas any more than they can send
/// a message, in either direction.
#[tokio::test]
async fn a_blocked_dm_pair_cannot_use_the_canvas_in_either_direction() {
    let (store, _guard) = support::new_store("slimm-dm-canvas-test").await;
    let app = app(store.clone());

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    let (status, opened) = open_dm(&app, &alice_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);
    let channel_id = opened["channel_id"].as_str().unwrap().to_owned();

    assert_eq!(
        block(&app, &alice_token, &bob_id).await,
        StatusCode::NO_CONTENT
    );

    assert_eq!(
        place_object(&app, &channel_id, &bob_token).await,
        StatusCode::FORBIDDEN,
        "the blocked party must not be able to use the canvas"
    );
    assert_eq!(
        place_object(&app, &channel_id, &alice_token).await,
        StatusCode::FORBIDDEN,
        "the blocker must not be able to either"
    );
}

/// Blocking hides the canvas outright, unlike message history, which a block
/// deliberately leaves readable.
///
/// Not an accident and not symmetric: reading messages needs `VIEW_CHANNEL`
/// alone, while every canvas route including the viewport read also needs
/// `USE_CANVAS`, and that bit is defined as "view and draw" in one piece - so
/// removing it removes viewing too. `store/dms.rs`'s `BLOCKED_DENY` doc
/// carries the full reasoning and the open question about splitting the bit.
/// This pins the behaviour so neither side can drift without a failing test.
#[tokio::test]
async fn a_block_hides_the_canvas_from_reads_not_just_writes() {
    let (store, _guard) = support::new_store("slimm-dm-canvas-test").await;
    let app = app(store.clone());

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    let (status, opened) = open_dm(&app, &alice_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);
    let channel_id = opened["channel_id"].as_str().unwrap().to_owned();

    let viewport =
        format!("/channels/{channel_id}/canvas/objects?min_x=0&min_y=0&max_x=100&max_y=100");

    let before = app
        .clone()
        .oneshot(request("GET", &viewport, Some(&bob_token), None))
        .await
        .unwrap()
        .status();
    assert_eq!(before, StatusCode::OK, "sanity: readable before the block");

    assert_eq!(
        block(&app, &alice_token, &bob_id).await,
        StatusCode::NO_CONTENT
    );

    let after = app
        .clone()
        .oneshot(request("GET", &viewport, Some(&bob_token), None))
        .await
        .unwrap()
        .status();
    assert_eq!(
        after,
        StatusCode::FORBIDDEN,
        "USE_CANVAS bundles viewing with drawing, so a block takes both"
    );
}
