// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A DM with yourself: opening it, its privacy, and that it lists and syncs
//! the same way any other channel does. Split out of `dms.rs` once the two
//! files together would have crossed the file-budget ceiling; see that
//! file's own doc comment for the rest of the DM invariants.

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

/// A member with a session, built straight through the store; see `dms.rs`'s
/// own copy of this helper for why it bypasses `/auth/register`.
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

async fn send(app: &Router, channel_id: &str, token: &str, content: &str) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": content })),
        ))
        .await
        .unwrap();
    let status = response.status();
    (status, json_body(response).await)
}

/// Opening a DM with yourself is a personal space, not an error: the pair
/// (a, a) is exactly what a caller messaging nobody but themselves needs.
/// Migration 0025 widened the pair ordering constraint to admit it, and it
/// is idempotent the same way an ordinary pair is.
#[tokio::test]
async fn opening_a_dm_with_yourself_creates_a_personal_space() {
    let (store, _guard) = support::new_store("slimm-dms-personal-space-test").await;
    let app = app(store.clone());

    let (alice_token, alice_id) = register(&store, "alice").await;

    let (status, opened) = open_dm(&app, &alice_token, &alice_id).await;
    assert_eq!(status, StatusCode::OK);
    let channel_id = opened["channel_id"].as_str().unwrap().to_owned();
    assert_eq!(
        opened["user"]["id"], alice_id,
        "the personal space's other participant is the caller themself"
    );

    let (status, reopened) = open_dm(&app, &alice_token, &alice_id).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        reopened["channel_id"].as_str().unwrap(),
        channel_id,
        "reopening must converge on the same channel, not create a second one"
    );

    let (status, _) = send(&app, &channel_id, &alice_token, "buy milk").await;
    assert_eq!(
        status,
        StatusCode::OK,
        "the caller can send into their own personal space"
    );

    let read = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/messages"),
            Some(&alice_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(read.status(), StatusCode::OK);
    assert_eq!(json_body(read).await.as_array().unwrap().len(), 1);
}

/// Nobody else, ADMINISTRATOR included, can read or send into a personal
/// space that is not theirs - the same guarantee an ordinary DM carries,
/// since a personal space runs through the identical `dm_permissions` check.
#[tokio::test]
async fn a_personal_space_is_private_even_to_an_administrator() {
    let (store, _guard) = support::new_store("slimm-dms-personal-space-test").await;
    let app = app(store.clone());

    let (admin_token, _admin_id) = register(&store, "admin").await;
    let (alice_token, alice_id) = register(&store, "alice").await;

    let (status, opened) = open_dm(&app, &alice_token, &alice_id).await;
    assert_eq!(status, StatusCode::OK);
    let channel_id = opened["channel_id"].as_str().unwrap().to_owned();

    let read = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/messages"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        read.status(),
        StatusCode::FORBIDDEN,
        "ADMINISTRATOR must not be able to read someone else's personal space"
    );

    let (status, _) = send(&app, &channel_id, &admin_token, "peeking").await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "ADMINISTRATOR must not be able to post into someone else's personal space"
    );
}

/// The personal space appears in `GET /dms` and, once written to, in
/// `/sync` - the same two surfaces every other channel reaches a second
/// device through. This is what makes "syncs across devices" true rather
/// than assumed.
#[tokio::test]
async fn a_personal_space_lists_and_syncs_like_any_other_channel() {
    let (store, _guard) = support::new_store("slimm-dms-personal-space-test").await;
    let app = app(store.clone());

    let (alice_token, alice_id) = register(&store, "alice").await;
    let (status, opened) = open_dm(&app, &alice_token, &alice_id).await;
    assert_eq!(status, StatusCode::OK);
    let channel_id = opened["channel_id"].as_str().unwrap().to_owned();

    let (status, sent) = send(&app, &channel_id, &alice_token, "note to self").await;
    assert_eq!(status, StatusCode::OK);
    let seq = sent["seq"].as_i64().unwrap();

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/dms", Some(&alice_token), None))
            .await
            .unwrap(),
    )
    .await;
    let conversations = listed.as_array().unwrap();
    assert_eq!(conversations.len(), 1);
    assert_eq!(conversations[0]["channel_id"], channel_id);
    assert_eq!(
        conversations[0]["user"]["id"], alice_id,
        "a second device discovering this channel must be told who it is with: themself"
    );

    // A second device's cold sync, from seq 0, must see the note.
    let synced = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/sync",
                Some(&alice_token),
                Some(json!({ "scopes": [{ "channel_id": channel_id, "after_seq": 0 }] })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let scopes = synced["scopes"].as_array().unwrap();
    assert_eq!(scopes.len(), 1, "sync must include the personal space");
    let messages = scopes[0]["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0]["seq"].as_i64().unwrap(), seq);
}
