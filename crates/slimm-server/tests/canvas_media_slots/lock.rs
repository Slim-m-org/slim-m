// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The shared lock invariant migration `0040`'s own doc describes: nobody
//! may drag a locked tile, not only the arranging client's own UI.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::fixtures::{put_slot_request, state_for, user_ticket};

fn locked_body(x: f64, y: f64, locked: bool) -> Value {
    json!({
        "x": x, "y": y, "w": 360.0, "h": 203.0,
        "locked": locked, "sent_to_back": false,
    })
}

/// Migration `0040`'s own doc calls this "the same shared-lock behaviour
/// Figma and FigJam themselves use" - nobody may drag a locked tile, not
/// only the arranging client's own UI. Mutation-tested: dropping the lock
/// check in `store/canvas_media_slots.rs::upsert_canvas_media_slot` fails
/// exactly this test.
#[tokio::test]
async fn a_locked_slot_refuses_a_move_that_would_leave_it_locked() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-locked-move");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    let (access, _ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_access, _ticket, _bob) = user_ticket(&store, "bob").await;
    let state = state_for(&store);

    let response = http::router(state.clone())
        .oneshot(put_slot_request(
            channel,
            &access,
            "screen",
            alice,
            locked_body(10.0, 10.0, true),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let response = http::router(state.clone())
        .oneshot(put_slot_request(
            channel,
            &bob_access,
            "screen",
            alice,
            locked_body(500.0, 500.0, true),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);

    let slots = store.list_canvas_media_slots(channel).await.unwrap();
    assert_eq!(slots.len(), 1);
    assert_eq!(slots[0].x, 10.0, "the locked tile must not have moved");
    assert_eq!(slots[0].y, 10.0);
}

/// Unlocking is itself unrestricted - anyone with `USE_CANVAS` may unlock
/// whatever anyone else locked - and a move is free again once it lands.
#[tokio::test]
async fn unlocking_a_slot_frees_the_next_move() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-unlock");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    let (access, _ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_access, _ticket, _bob) = user_ticket(&store, "bob").await;
    let state = state_for(&store);

    let response = http::router(state.clone())
        .oneshot(put_slot_request(
            channel,
            &access,
            "screen",
            alice,
            locked_body(10.0, 10.0, true),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let response = http::router(state.clone())
        .oneshot(put_slot_request(
            channel,
            &bob_access,
            "screen",
            alice,
            locked_body(10.0, 10.0, false),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "unlocking is always allowed"
    );

    let response = http::router(state.clone())
        .oneshot(put_slot_request(
            channel,
            &bob_access,
            "screen",
            alice,
            locked_body(500.0, 500.0, false),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "a move is free once unlocked"
    );

    let slots = store.list_canvas_media_slots(channel).await.unwrap();
    assert_eq!(slots[0].x, 500.0);
}

/// Toggling depth, or re-posting the same geometry, is never gated by lock -
/// only a move or resize that would leave the tile locked is refused.
#[tokio::test]
async fn a_locked_slots_depth_may_still_be_toggled() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-locked-depth");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    let (access, _ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let state = state_for(&store);

    let response = http::router(state.clone())
        .oneshot(put_slot_request(
            channel,
            &access,
            "camera",
            alice,
            locked_body(10.0, 10.0, true),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let mut body = locked_body(10.0, 10.0, true);
    body["sent_to_back"] = json!(true);
    let response = http::router(state.clone())
        .oneshot(put_slot_request(channel, &access, "camera", alice, body))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let slots = store.list_canvas_media_slots(channel).await.unwrap();
    assert!(slots[0].sent_to_back);
}

/// A client that missed the lock frame sends its stale `locked: false` with a
/// drag; the stored lock decides, so the tile neither moves nor unlocks.
#[tokio::test]
async fn a_move_that_claims_the_slot_is_unlocked_is_still_refused() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-stale-lock");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    let (access, _ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_access, _ticket, _bob) = user_ticket(&store, "bob").await;
    let state = state_for(&store);
    let put = |token: &str, body: Value| put_slot_request(channel, token, "screen", alice, body);

    let locked = http::router(state.clone())
        .oneshot(put(&access, locked_body(10.0, 10.0, true)))
        .await
        .unwrap();
    assert_eq!(locked.status(), StatusCode::OK);
    let stale = http::router(state.clone())
        .oneshot(put(&bob_access, locked_body(500.0, 500.0, false)))
        .await
        .unwrap();
    assert_eq!(stale.status(), StatusCode::CONFLICT);

    let slots = store.list_canvas_media_slots(channel).await.unwrap();
    assert_eq!((slots[0].x, slots[0].locked), (10.0, true));
}
