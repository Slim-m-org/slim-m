// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The canvas viewport route: its permission gate is evaluated per channel and
//! wants the canvas bit as well as the view bit, and a rectangle it cannot
//! honour is refused rather than quietly clamped into a different answer.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{CanvasObjectId, ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{PlaceRequest, Store};
use tower::ServiceExt;

mod support;

use support::app::app;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-canvas-http");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    (
        Store::new(db::connect(&config).await.expect("connect + migrate")),
        guard,
    )
}

/// A signed-in member, built through the store for the same reason the pin
/// tests do it: registration policy is somebody else's test.
async fn register(store: &Store, username: &str) -> (String, UserId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id)
}

async fn get(app: &Router, uri: &str, token: &str) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(uri)
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn region(channel: ChannelId) -> String {
    format!("/channels/{channel}/canvas/objects?min_x=-100&min_y=-100&max_x=100&max_y=100")
}

async fn place(store: &Store, channel: ChannelId, author: UserId, x: f64) {
    store
        .place_canvas_object(
            channel,
            author,
            CanvasObjectId::generate(),
            PlaceRequest {
                kind: "stroke",
                bounds: (x, 0.0, 10.0, 10.0),
                props: "{}",
                attachment: None,
            },
        )
        .await
        .expect("placed");
}

/// Seeing a channel is not seeing its canvas. A member with VIEW_CHANNEL and
/// no USE_CANVAS is refused, which matters because the canvas is where a voice
/// room's shared work lives and a listen-only guest is a real role.
#[tokio::test]
async fn reading_a_canvas_needs_the_canvas_bit_as_well_as_the_view_bit() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let drawers = store
        .create_role("drawers", Permissions::USE_CANVAS, false)
        .await
        .unwrap();
    let app = app(store.clone());
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;

    let (token, user) = register(&store, "ann").await;
    let (status, body) = get(&app, &region(channel), &token).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");

    store.assign_role(user, drawers).await.unwrap();
    let (status, body) = get(&app, &region(channel), &token).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["objects"], Value::Array(Vec::new()));
    assert_eq!(body["has_more"], Value::Bool(false));
}

/// The gate reads the evaluator's per-channel answer, so a role that grants
/// the canvas everywhere still loses in a channel that denies it. A
/// deployment-wide check of the wrong shape is a bug this project has already
/// shipped once, in report resolution.
#[tokio::test]
async fn the_canvas_gate_is_evaluated_per_channel() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let open = store.create_channel("open", "voice").await.unwrap().id;
    let closed = store.create_channel("closed", "voice").await.unwrap().id;

    let (token, user) = register(&store, "ann").await;
    store
        .set_member_overwrite(closed, user, Permissions::NONE, Permissions::USE_CANVAS)
        .await
        .unwrap();

    assert_eq!(get(&app, &region(open), &token).await.0, StatusCode::OK);
    assert_eq!(
        get(&app, &region(closed), &token).await.0,
        StatusCode::FORBIDDEN
    );
}

/// A rectangle the server cannot honour is refused. Clamping it instead would
/// answer a question nobody asked, which on a canvas means showing the wrong
/// part of the world with no sign anything went wrong.
#[tokio::test]
async fn a_rectangle_the_server_cannot_honour_is_refused() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let (token, _) = register(&store, "ann").await;

    let base = format!("/channels/{channel}/canvas/objects");
    for query in [
        "min_x=100&min_y=0&max_x=-100&max_y=10",
        "min_x=0&min_y=0&max_x=99000000&max_y=10",
        "min_x=0&min_y=0&max_x=10&max_y=10&prev_min_x=0",
    ] {
        let (status, body) = get(&app, &format!("{base}?{query}"), &token).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{query} answered {body}");
    }
}

/// A region holding more than the caller asked for says so, rather than
/// silently truncating the canvas it draws.
#[tokio::test]
async fn a_crowded_region_reports_that_it_held_something_back() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let (token, user) = register(&store, "ann").await;
    place(&store, channel, user, 0.0).await;
    place(&store, channel, user, 20.0).await;

    let (status, body) = get(&app, &format!("{}&limit=1", region(channel)), &token).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["objects"].as_array().unwrap().len(), 1);
    assert_eq!(body["has_more"], Value::Bool(true));
    assert_eq!(body["latest_seq"], Value::from(2));
}
