// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! API2: channel creation accepts an optional client-supplied id and is
//! idempotent on it, the same contract `send_message` already gives a
//! message send (see `message_endpoints.rs::send_is_idempotent_over_http`).
//! See `category_create_idempotency.rs` and `role_create_idempotency.rs` for
//! the same contract on the other two creatable resources.
//!
//! A retry with the same id returns the row already stored under it rather
//! than a second one and publishes no second hub event, a fresh id makes a
//! distinct row, an omitted id still creates (the pre-API2 wire shape keeps
//! working), and an id already used by a DM or a thread - which share
//! `channels`' id namespace - is a conflict rather than a wrong-typed 200.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::MessageId;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
use tokio::sync::broadcast;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

/// Builds the router and hands back a fresh event subscription taken before
/// any request runs, so every test can assert on exactly the events its own
/// requests caused.
fn app_with_events(store: Store) -> (Router, broadcast::Receiver<Event>) {
    let state = AppState {
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
    };
    let events = state.hub.subscribe();
    (http::router(state), events)
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

/// Registers the deployment's first account, which claims real bootstrap and
/// so holds ADMINISTRATOR - enough for every create this file exercises
/// (MANAGE_CHANNELS and MANAGE_ROLES both resolve true under it), without
/// each test having to hand-seed an `everyone` role of its own.
async fn register_admin(store: &Store) -> (String, slimm_server::ids::UserId) {
    let account = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (token, account.id)
}

/// Counts how many pending events on `events` match `matches`, draining the
/// channel so a later assertion in the same test starts from empty again.
fn count_matching(
    events: &mut broadcast::Receiver<Event>,
    matches: impl Fn(&Event) -> bool,
) -> usize {
    let mut count = 0;
    while let Ok(event) = events.try_recv() {
        if matches(&event) {
            count += 1;
        }
    }
    count
}

/// Real bootstrap (via [`register_admin`]) seeds a default `general` channel
/// of its own, so every count here is a delta over a channel-list baseline
/// taken before this test's creates, not an absolute count.
async fn channel_count(app: &Router, token: &str) -> usize {
    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/channels", Some(token), None))
            .await
            .unwrap(),
    )
    .await;
    listed.as_array().unwrap().len()
}

#[tokio::test]
async fn create_channel_retry_returns_the_same_row_and_publishes_once() {
    let (store, _guard) = support::new_store("slimm-channel-create-idempotency-test").await;
    let (token, _admin_id) = register_admin(&store).await;
    let (app, mut events) = app_with_events(store.clone());
    let baseline = channel_count(&app, &token).await;

    let id = Uuid::now_v7().to_string();
    let create = |name: &str| {
        request(
            "POST",
            "/channels",
            Some(&token),
            Some(json!({ "id": id, "name": name })),
        )
    };

    let first = json_body(app.clone().oneshot(create("idem-general")).await.unwrap()).await;
    let retry = json_body(
        app.clone()
            .oneshot(create("renamed-on-retry"))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(first["id"], retry["id"]);
    assert_eq!(
        retry["name"], "idem-general",
        "retry returns the stored row, not the new name"
    );

    assert_eq!(
        channel_count(&app, &token).await,
        baseline + 1,
        "no duplicate row"
    );

    let created = count_matching(&mut events, |e| matches!(e, Event::ChannelCreated(..)));
    assert_eq!(created, 1, "the retry must not fan out a second event");
}

#[tokio::test]
async fn create_channel_with_a_fresh_id_makes_a_distinct_row() {
    let (store, _guard) = support::new_store("slimm-channel-create-idempotency-test").await;
    let (token, _admin_id) = register_admin(&store).await;
    let (app, _events) = app_with_events(store.clone());
    let baseline = channel_count(&app, &token).await;

    let first = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/channels",
                Some(&token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "name": "idem-a" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let second = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/channels",
                Some(&token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "name": "idem-b" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_ne!(first["id"], second["id"]);
    assert_eq!(channel_count(&app, &token).await, baseline + 2);
}

#[tokio::test]
async fn create_channel_without_an_id_still_creates() {
    let (store, _guard) = support::new_store("slimm-channel-create-idempotency-test").await;
    let (token, _admin_id) = register_admin(&store).await;
    let (app, _events) = app_with_events(store.clone());

    let first = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/channels",
                Some(&token),
                Some(json!({ "name": "general" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let second = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/channels",
                Some(&token),
                Some(json!({ "name": "spare" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_ne!(first["id"], second["id"], "each omitted-id create is fresh");
}

/// `channels` holds text/voice channels, DM channels, and threads under one
/// id namespace. A colliding id must come back as a conflict, never a
/// wrong-typed 200 (a POST /channels response claiming to be a DM or a
/// thread) and never a 500 from the unscoped probe falling through to an
/// INSERT that hits the same primary key.
#[tokio::test]
async fn create_channel_refuses_an_id_already_used_by_a_dm_or_a_thread() {
    let (store, _guard) = support::new_store("slimm-channel-create-idempotency-test").await;
    let (token, admin_id) = register_admin(&store).await;
    let other = store.create_user("bob", "bob").await.unwrap();
    let dm = store.open_dm(admin_id, other.id).await.unwrap();

    let host = store.create_channel("host", "text").await.unwrap();
    let message_id = MessageId::generate();
    store
        .send_message(NewMessage::plain(host.id, admin_id, message_id, "hi"))
        .await
        .unwrap();
    let thread = store.open_thread(host.id, message_id).await.unwrap();

    let (app, _events) = app_with_events(store.clone());

    for existing_id in [dm.id.to_string(), thread.channel.id.to_string()] {
        let response = app
            .clone()
            .oneshot(request(
                "POST",
                "/channels",
                Some(&token),
                Some(json!({ "id": existing_id, "name": "collide" })),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::CONFLICT,
            "an id already used by a dm or a thread must never come back as a wrong-typed 200"
        );
    }
}
