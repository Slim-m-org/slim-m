// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-channel slow mode: the send-path enforcement, its MANAGE_CHANNELS
//! exemption, the idempotent-retry carve-out, and the PATCH route that sets
//! it. Split out from `message_endpoints.rs` and `channel_topic.rs` the same
//! way `channel_topic.rs` itself split off `channels.rs`.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-channel-slow-mode-test");
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
/// `channel_topic.rs`'s own copy of this helper for why it bypasses
/// `/auth/register`.
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

fn send(uri: &str, token: &str, content: &str) -> Request<Body> {
    request(
        "POST",
        uri,
        Some(token),
        Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
    )
}

/// A non-exempt member's second message inside the window is refused with a
/// 429 naming the seconds remaining, both in the body and as `Retry-After`.
#[tokio::test]
async fn a_second_message_inside_the_window_is_refused_with_the_remaining_time() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    store.update_channel_slow_mode(channel.id, 5).await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let uri = format!("/channels/{}/messages", channel.id);

    let first = app
        .clone()
        .oneshot(send(&uri, &token, "one"))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);

    let second = app
        .clone()
        .oneshot(send(&uri, &token, "two"))
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::TOO_MANY_REQUESTS);
    let retry_after_header: i64 = second
        .headers()
        .get("retry-after")
        .expect("a slow-mode refusal names a Retry-After")
        .to_str()
        .unwrap()
        .parse()
        .unwrap();
    assert!((1..=5).contains(&retry_after_header));
    let body = json_body(second).await;
    let retry_after_body = body["retry_after_seconds"].as_i64().unwrap();
    assert_eq!(retry_after_body, retry_after_header);
    assert!(body["error"].as_str().unwrap().contains("slow mode"));
}

/// A `MANAGE_CHANNELS` holder is exempt: slow mode is the lesser lever
/// between "nothing" and a full timeout, so its exemption follows the same
/// bit a timeout would otherwise be the only way around.
#[tokio::test]
async fn a_manage_channels_holder_is_exempt() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    store.update_channel_slow_mode(channel.id, 5).await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let uri = format!("/channels/{}/messages", channel.id);

    let first = app
        .clone()
        .oneshot(send(&uri, &token, "one"))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    let second = app
        .clone()
        .oneshot(send(&uri, &token, "two"))
        .await
        .unwrap();
    assert_eq!(
        second.status(),
        StatusCode::OK,
        "a manager is never slow-moded"
    );
}

/// Setting slow mode is gated on the same MANAGE_CHANNELS check renaming and
/// topic edits use.
#[tokio::test]
async fn setting_slow_mode_without_manage_channels_is_forbidden() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", channel.id),
            Some(&token),
            Some(json!({ "slow_mode_seconds": 30 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// A manager can set slow mode on its own, with neither `name` nor `topic` in
/// the same request, and it round-trips through the response.
#[tokio::test]
async fn manager_can_set_slow_mode_alone_and_it_round_trips() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", channel.id),
            Some(&token),
            Some(json!({ "slow_mode_seconds": 30 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["slow_mode_seconds"], 30);
    // Not in this request, so it must be untouched.
    assert_eq!(body["name"], "general");
}

/// A `slow_mode_seconds` outside 0..=21600 is refused, not clamped.
#[tokio::test]
async fn slow_mode_seconds_out_of_range_is_rejected() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let too_high = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", channel.id),
            Some(&token),
            Some(json!({ "slow_mode_seconds": 21601 })),
        ))
        .await
        .unwrap();
    assert_eq!(too_high.status(), StatusCode::BAD_REQUEST);

    let negative = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", channel.id),
            Some(&token),
            Some(json!({ "slow_mode_seconds": -1 })),
        ))
        .await
        .unwrap();
    assert_eq!(negative.status(), StatusCode::BAD_REQUEST);
}

/// An idempotent retry of a send that already succeeded must never be refused
/// for arriving "too soon" - it is not a second message, it is the same one.
#[tokio::test]
async fn an_idempotent_retry_is_never_slow_moded() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    store
        .update_channel_slow_mode(channel.id, 60)
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let uri = format!("/channels/{}/messages", channel.id);
    let message_id = Uuid::now_v7().to_string();
    let body = json!({ "id": message_id, "content": "original" });

    let first = app
        .clone()
        .oneshot(request("POST", &uri, Some(&token), Some(body.clone())))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);

    let retry = app
        .clone()
        .oneshot(request("POST", &uri, Some(&token), Some(body)))
        .await
        .unwrap();
    assert_eq!(
        retry.status(),
        StatusCode::OK,
        "a retry of an already-stored send must not be slow-moded"
    );
}

/// `slow_mode_seconds = 0`, the default, disables enforcement entirely.
#[tokio::test]
async fn zero_disables_slow_mode() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let uri = format!("/channels/{}/messages", channel.id);

    let first = app
        .clone()
        .oneshot(send(&uri, &token, "one"))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    let second = app
        .clone()
        .oneshot(send(&uri, &token, "two"))
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::OK);
}

/// A non-exempt member (the first account bootstraps as the administrator)
/// in a channel whose slow mode is `seconds`, with a thread open on a message
/// of their own. Returns the app, the member's token and the thread's send URI.
async fn member_with_a_thread(seconds: i64) -> (Router, String, String, support::TestDbGuard) {
    let (store, guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    store
        .update_channel_slow_mode(channel.id, seconds)
        .await
        .unwrap();
    let app = app(store.clone());
    let _admin = register(&store, "admin").await;
    let token = register(&store, "bob").await;
    let uri = format!("/channels/{}/messages", channel.id);
    let root = app
        .clone()
        .oneshot(send(&uri, &token, "root"))
        .await
        .unwrap();
    assert_eq!(root.status(), StatusCode::OK);
    let root_id = json_body(root).await["id"].as_str().unwrap().to_owned();
    let thread = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("{uri}/{root_id}/thread"),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(thread.status(), StatusCode::OK);
    let thread_id = json_body(thread).await["id"].as_str().unwrap().to_owned();
    (app, token, format!("/channels/{thread_id}/messages"), guard)
}

/// A thread has no slow mode of its own, so it follows its parent channel's
/// interval. The window is the thread's own: the first reply is not held back
/// by the root message sent moments earlier in the channel.
#[tokio::test]
async fn a_thread_follows_its_parent_channels_slow_mode() {
    let (app, token, thread_uri, _guard) = member_with_a_thread(60).await;

    let first = app
        .clone()
        .oneshot(send(&thread_uri, &token, "one"))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    let second = app
        .clone()
        .oneshot(send(&thread_uri, &token, "two"))
        .await
        .unwrap();
    assert_eq!(
        second.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "second thread message inside the parent's 60s slow mode"
    );
}

/// The control: a parent with slow mode off leaves its threads unlimited.
#[tokio::test]
async fn a_thread_of_a_channel_without_slow_mode_is_unlimited() {
    let (app, token, thread_uri, _guard) = member_with_a_thread(0).await;

    for content in ["one", "two", "three"] {
        let sent = app
            .clone()
            .oneshot(send(&thread_uri, &token, content))
            .await
            .unwrap();
        assert_eq!(sent.status(), StatusCode::OK);
    }
}
