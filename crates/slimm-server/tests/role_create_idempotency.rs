// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! API2: role creation accepts an optional client-supplied id and is
//! idempotent on it, the same contract `send_message` already gives a
//! message send (see `message_endpoints.rs::send_is_idempotent_over_http`).
//! See `channel_create_idempotency.rs` and `category_create_idempotency.rs`
//! for the same contract on the other two creatable resources.
//!
//! A retry with the same id returns the row already stored under it rather
//! than a second one and publishes no second hub event, a fresh id makes a
//! distinct row, an omitted id still creates (the pre-API2 wire shape keeps
//! working), and an id already used by the bootstrap `@everyone` role -
//! which shares `roles`' id namespace with every ordinary role - is a
//! conflict rather than a wrong-typed 200.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::{Event, Hub};
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
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
        if matches(&event.into_inner()) {
            count += 1;
        }
    }
    count
}

#[tokio::test]
async fn create_role_retry_returns_the_same_row_and_publishes_once() {
    let (store, _guard) = support::new_store("slimm-role-create-idempotency-test").await;
    let (token, _admin_id) = register_admin(&store).await;
    let (app, mut events) = app_with_events(store.clone());

    let id = Uuid::now_v7().to_string();
    let create = |permissions: i64| {
        request(
            "POST",
            "/roles",
            Some(&token),
            Some(json!({ "id": id, "name": "scouts", "permissions": permissions })),
        )
    };

    let first = json_body(app.clone().oneshot(create(0)).await.unwrap()).await;
    let retry = json_body(
        app.clone()
            .oneshot(create(
                slimm_server::permissions::Permissions::MANAGE_MESSAGES.bits(),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(first["id"], retry["id"]);
    assert_eq!(
        retry["permissions"], 0,
        "retry returns the stored row, not the new permissions"
    );

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/roles", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    let matching = listed
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["name"] == "scouts")
        .count();
    assert_eq!(matching, 1, "no duplicate row");

    let created = count_matching(&mut events, |e| matches!(e, Event::RoleChanged { .. }));
    assert_eq!(created, 1, "the retry must not fan out a second event");
}

#[tokio::test]
async fn create_role_with_a_fresh_id_makes_a_distinct_row() {
    let (store, _guard) = support::new_store("slimm-role-create-idempotency-test").await;
    let (token, _admin_id) = register_admin(&store).await;
    let (app, _events) = app_with_events(store.clone());

    let first = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(&token),
                Some(
                    json!({ "id": Uuid::now_v7().to_string(), "name": "scouts", "permissions": 0 }),
                ),
            ))
            .await
            .unwrap(),
    )
    .await;
    let second = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(&token),
                Some(
                    json!({ "id": Uuid::now_v7().to_string(), "name": "guides", "permissions": 0 }),
                ),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_ne!(first["id"], second["id"]);
}

#[tokio::test]
async fn create_role_without_an_id_still_creates() {
    let (store, _guard) = support::new_store("slimm-role-create-idempotency-test").await;
    let (token, _admin_id) = register_admin(&store).await;
    let (app, _events) = app_with_events(store.clone());

    let first = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(&token),
                Some(json!({ "name": "scouts", "permissions": 0 })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let second = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(&token),
                Some(json!({ "name": "guides", "permissions": 0 })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_ne!(first["id"], second["id"], "each omitted-id create is fresh");
}

/// `roles` holds the bootstrap `@everyone` role in the same id namespace as
/// every ordinary role. A colliding id must come back as a conflict, never
/// a wrong-typed 200 that hands the caller `@everyone`'s own row back as if
/// it were the role they just asked to create.
#[tokio::test]
async fn create_role_refuses_an_id_already_used_by_the_everyone_role() {
    let (store, _guard) = support::new_store("slimm-role-create-idempotency-test").await;
    let (token, _admin_id) = register_admin(&store).await;
    let everyone = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .expect("bootstrap seeds the @everyone role");
    let (app, _events) = app_with_events(store.clone());

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/roles",
            Some(&token),
            Some(json!({ "id": everyone.id.to_string(), "name": "collide", "permissions": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::CONFLICT,
        "an id already used by @everyone must never come back as a wrong-typed 200"
    );
}
