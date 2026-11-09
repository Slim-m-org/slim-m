// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A poll is a message send underneath, so creating one must do what a send
//! does after the permission check: honour slow mode, advance the author's own
//! read marker, tell a thread's parent its reply count moved, and still
//! announce itself when a step after the commit fails.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::hub::{Event, Hub, MessageEvent};
use slimm_server::permissions::Permissions;
use slimm_server::store::{Channel, Store};
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{json_body, register_token as register, request};

struct World {
    store: Store,
    pool: sqlx::SqlitePool,
    router: Router,
    hub: Hub,
    token: String,
    channel: Channel,
    _guard: support::TestDbGuard,
}

async fn world(prefix: &str, slow_mode_seconds: i64) -> World {
    let (store, pool, guard) = support::new_store_with_pool(prefix).await;
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    store
        .create_role("everyone", view_send, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    if slow_mode_seconds > 0 {
        store
            .update_channel_slow_mode(channel.id, slow_mode_seconds)
            .await
            .unwrap();
    }
    let hub = Hub::new();
    let router = support::app::builder(store.clone())
        .hub(hub.clone())
        .router();
    let _admin = register(&store, "admin").await;
    let token = register(&store, "nia").await;
    World {
        store,
        pool,
        router,
        hub,
        token,
        channel,
        _guard: guard,
    }
}

fn poll_request(channel: &str, token: &str, id: &str, caption: &str) -> Request<Body> {
    request(
        "POST",
        &format!("/channels/{channel}/messages/polls"),
        Some(token),
        Some(json!({
            "id": id,
            "content": caption,
            "question": "tabs or spaces?",
            "options": ["tabs", "spaces"],
        })),
    )
}

fn fresh_poll(channel: &str, token: &str) -> Request<Body> {
    poll_request(channel, token, &Uuid::now_v7().to_string(), "")
}

async fn status_of(router: &Router, req: Request<Body>) -> StatusCode {
    router.clone().oneshot(req).await.unwrap().status()
}

#[derive(Default)]
struct Seen {
    created: usize,
    created_with_poll: usize,
    read_marker: bool,
    thread_updated: bool,
}

fn drain(rx: &mut tokio::sync::broadcast::Receiver<Event>) -> Seen {
    let mut seen = Seen::default();
    while let Ok(event) = rx.try_recv() {
        match event {
            Event::ReadStateChanged { .. } => seen.read_marker = true,
            Event::Message(MessageEvent::ThreadUpdated { .. }) => seen.thread_updated = true,
            Event::Message(MessageEvent::Created { poll, .. }) => {
                seen.created += 1;
                seen.created_with_poll += usize::from(poll.is_some());
            }
            _ => {}
        }
    }
    seen
}

#[tokio::test]
async fn a_second_poll_inside_the_slow_mode_window_is_refused() {
    let w = world("slimm-poll-tail-slow", 60).await;
    let c = w.channel.id.to_string();
    assert_eq!(
        status_of(&w.router, fresh_poll(&c, &w.token)).await,
        StatusCode::OK
    );
    assert_eq!(
        status_of(&w.router, fresh_poll(&c, &w.token)).await,
        StatusCode::TOO_MANY_REQUESTS,
        "second poll inside a 60s slow mode window"
    );
}

#[tokio::test]
async fn a_poll_counts_toward_the_slow_mode_window_of_a_message() {
    let w = world("slimm-poll-tail-slow-message", 60).await;
    let c = w.channel.id.to_string();
    let message = request(
        "POST",
        &format!("/channels/{c}/messages"),
        Some(&w.token),
        Some(json!({ "id": Uuid::now_v7().to_string(), "content": "hi" })),
    );
    assert_eq!(status_of(&w.router, message).await, StatusCode::OK);
    assert_eq!(
        status_of(&w.router, fresh_poll(&c, &w.token)).await,
        StatusCode::TOO_MANY_REQUESTS
    );
}

#[tokio::test]
async fn a_retried_poll_is_not_refused_by_slow_mode() {
    let w = world("slimm-poll-tail-retry", 60).await;
    let c = w.channel.id.to_string();
    let id = Uuid::now_v7().to_string();
    assert_eq!(
        status_of(&w.router, poll_request(&c, &w.token, &id, "")).await,
        StatusCode::OK
    );
    assert_eq!(
        status_of(&w.router, poll_request(&c, &w.token, &id, "")).await,
        StatusCode::OK,
        "an idempotent retry inside the window"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn parallel_polls_pass_slow_mode_only_once() {
    let w = world("slimm-poll-tail-parallel", 60).await;
    let c = w.channel.id.to_string();
    let mut handles = Vec::new();
    for _ in 0..8 {
        let router = w.router.clone();
        let req = fresh_poll(&c, &w.token);
        handles.push(tokio::spawn(async move { status_of(&router, req).await }));
    }
    let mut passed = 0;
    for handle in handles {
        passed += usize::from(handle.await.unwrap() == StatusCode::OK);
    }
    assert_eq!(passed, 1, "exactly one of 8 parallel polls may pass");
}

#[tokio::test]
async fn a_poll_advances_the_authors_read_marker() {
    let w = world("slimm-poll-tail-read", 0).await;
    let mut rx = w.hub.subscribe();
    let c = w.channel.id.to_string();
    assert_eq!(
        status_of(&w.router, fresh_poll(&c, &w.token)).await,
        StatusCode::OK
    );
    assert!(
        drain(&mut rx).read_marker,
        "creating a poll must advance the author's own read marker like a send does"
    );
}

#[tokio::test]
async fn a_poll_in_a_thread_updates_the_parent_reply_count() {
    let w = world("slimm-poll-tail-thread", 0).await;
    let c = w.channel.id.to_string();
    let root = Uuid::now_v7().to_string();
    let sent = request(
        "POST",
        &format!("/channels/{c}/messages"),
        Some(&w.token),
        Some(json!({ "id": root, "content": "root" })),
    );
    assert_eq!(status_of(&w.router, sent).await, StatusCode::OK);
    let opened = w
        .router
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{c}/messages/{root}/thread"),
            Some(&w.token),
            Some(json!({})),
        ))
        .await
        .unwrap();
    assert_eq!(opened.status(), StatusCode::OK);
    let thread_id = json_body(opened).await["id"].as_str().unwrap().to_owned();

    let mut rx = w.hub.subscribe();
    assert_eq!(
        status_of(&w.router, fresh_poll(&thread_id, &w.token)).await,
        StatusCode::OK
    );
    assert!(
        drain(&mut rx).thread_updated,
        "a poll created in a thread must publish ThreadUpdated for the parent"
    );
}

/// The stored poll must reach everyone watching even if a lookup after the commit fails.
#[tokio::test]
async fn a_poll_whose_mentions_cannot_be_stored_is_still_announced() {
    let w = world("slimm-poll-tail-mentions", 0).await;
    let _bob = register(&w.store, "bob").await;
    sqlx::query(
        "CREATE TRIGGER boom BEFORE INSERT ON message_mentions \
         BEGIN SELECT RAISE(ABORT, 'boom'); END",
    )
    .execute(&w.pool)
    .await
    .unwrap();
    let mut rx = w.hub.subscribe();
    let c = w.channel.id.to_string();
    let id = Uuid::now_v7().to_string();

    let first = status_of(&w.router, poll_request(&c, &w.token, &id, "hello @bob")).await;
    let seen = drain(&mut rx);
    let retry = status_of(&w.router, poll_request(&c, &w.token, &id, "hello @bob")).await;
    let after_retry = drain(&mut rx);

    assert_eq!(
        (first, seen.created, retry, after_retry.created),
        (StatusCode::OK, 1, StatusCode::OK, 0),
        "the poll answers 200 and is announced exactly once"
    );
}

#[tokio::test]
async fn a_poll_whose_tally_cannot_be_read_is_still_announced() {
    let w = world("slimm-poll-tail-tally", 0).await;
    sqlx::query("ALTER TABLE poll_votes RENAME TO poll_votes_away")
        .execute(&w.pool)
        .await
        .unwrap();
    let mut rx = w.hub.subscribe();
    let c = w.channel.id.to_string();

    let status = status_of(&w.router, fresh_poll(&c, &w.token)).await;
    let seen = drain(&mut rx);

    assert_eq!(
        (status, seen.created),
        (StatusCode::OK, 1),
        "the stored poll answers 200 and publishes one MessageCreated"
    );
}

#[tokio::test]
async fn a_poll_still_answers_with_its_poll_when_nothing_fails() {
    let w = world("slimm-poll-tail-control", 0).await;
    let mut rx = w.hub.subscribe();
    let c = w.channel.id.to_string();
    let response = w
        .router
        .clone()
        .oneshot(fresh_poll(&c, &w.token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body: Value = json_body(response).await;
    assert_eq!(body["poll"]["question"], "tabs or spaces?");
    let seen = drain(&mut rx);
    assert_eq!((seen.created, seen.created_with_poll), (1, 1));
}
