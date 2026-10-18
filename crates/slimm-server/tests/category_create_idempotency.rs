// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! API2: category creation accepts an optional client-supplied id and is
//! idempotent on it, the same contract `send_message` already gives a
//! message send (see `message_endpoints.rs::send_is_idempotent_over_http`).
//! See `channel_create_idempotency.rs` and `role_create_idempotency.rs` for
//! the same contract on the other two creatable resources.
//!
//! A retry with the same id returns the row already stored under it rather
//! than a second one and publishes no second hub event, a fresh id makes a
//! distinct row, and an omitted id still creates (the pre-API2 wire shape
//! keeps working). `channel_categories` is written by nothing but this
//! resource, so unlike channels and roles there is no wrong-typed-collision
//! case to cover here.

use axum::Router;
use serde_json::json;
use slimm_server::http::{self};
use slimm_server::hub::Event;
use slimm_server::store::Store;
use tokio::sync::broadcast;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{json_body, request};

/// Builds the router and hands back a fresh event subscription taken before
/// any request runs, so every test can assert on exactly the events its own
/// requests caused.
fn app_with_events(store: Store) -> (Router, broadcast::Receiver<Event>) {
    let state = support::app::state(store);
    let events = state.hub.subscribe();
    (http::router(state), events)
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

/// Migration 0031 seeds every fresh deployment with default `Text` and
/// `Voice` categories, so every count here is a delta over a
/// category-list baseline taken before this test's creates, the same reason a channel-list baseline in `channel_create_idempotency.rs`
/// is a delta rather than an absolute count.
async fn category_count(app: &Router, token: &str) -> usize {
    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/categories", Some(token), None))
            .await
            .unwrap(),
    )
    .await;
    listed.as_array().unwrap().len()
}

#[tokio::test]
async fn create_category_retry_returns_the_same_row_and_publishes_once() {
    let (store, _guard) = support::new_store("slimm-category-create-idempotency-test").await;
    let (token, _admin_id) = register_admin(&store).await;
    let (app, mut events) = app_with_events(store.clone());
    let baseline = category_count(&app, &token).await;

    let id = Uuid::now_v7().to_string();
    let create = |name: &str| {
        request(
            "POST",
            "/categories",
            Some(&token),
            Some(json!({ "id": id, "name": name })),
        )
    };

    let first = json_body(app.clone().oneshot(create("extras")).await.unwrap()).await;
    let retry = json_body(
        app.clone()
            .oneshot(create("renamed-on-retry"))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(first["id"], retry["id"]);
    assert_eq!(
        retry["name"], "extras",
        "retry returns the stored row, not the new name"
    );

    assert_eq!(
        category_count(&app, &token).await,
        baseline + 1,
        "no duplicate row"
    );

    let created = count_matching(&mut events, |e| matches!(e, Event::CategoryChanged));
    assert_eq!(created, 1, "the retry must not fan out a second event");
}

#[tokio::test]
async fn create_category_with_a_fresh_id_makes_a_distinct_row() {
    let (store, _guard) = support::new_store("slimm-category-create-idempotency-test").await;
    let (token, _admin_id) = register_admin(&store).await;
    let (app, _events) = app_with_events(store.clone());
    let baseline = category_count(&app, &token).await;

    let first = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/categories",
                Some(&token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "name": "extras" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let second = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/categories",
                Some(&token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "name": "more" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_ne!(first["id"], second["id"]);
    assert_eq!(category_count(&app, &token).await, baseline + 2);
}

#[tokio::test]
async fn create_category_without_an_id_still_creates() {
    let (store, _guard) = support::new_store("slimm-category-create-idempotency-test").await;
    let (token, _admin_id) = register_admin(&store).await;
    let (app, _events) = app_with_events(store.clone());

    let first = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/categories",
                Some(&token),
                Some(json!({ "name": "extras" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let second = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/categories",
                Some(&token),
                Some(json!({ "name": "more" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_ne!(first["id"], second["id"], "each omitted-id create is fresh");
}
