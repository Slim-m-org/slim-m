// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Placement, authorization, validation and persistence for a channel's
//! media slots - everything the shared lock invariant does not need on its
//! own; see `lock.rs` for that.

use axum::http::StatusCode;
use serde_json::Value;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::fixtures::{
    chrono_now_plus_ms, connect, list_slots_request, put_slot_request, read_frame, screen_body,
    serve, state_for, user_ticket,
};

/// The owner's own scenario, verbatim: move a tile, then come back to a
/// *fresh* `Store` over the same database file - the shape a real restart
/// takes, not merely a second read against a process that never stopped.
#[tokio::test]
async fn persists_across_a_restart() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-restart");
    let config = Config {
        port: 0,
        database_path: path.clone(),
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    let (access, _ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let response = http::router(state_for(&store))
        .oneshot(put_slot_request(
            channel,
            &access,
            "screen",
            alice,
            screen_body(120.0, 340.0),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    // A new pool over the same file - nothing here is in-memory state, the same guarantee a restart needs.
    let restarted = Store::new(db::connect(&config).await.unwrap());
    let response = http::router(state_for(&restarted))
        .oneshot(list_slots_request(channel, &access))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let json: Value = serde_json::from_slice(&body).unwrap();
    let slots = json["slots"].as_array().unwrap();
    assert_eq!(slots.len(), 1);
    assert_eq!(slots[0]["kind"], "screen");
    assert_eq!(slots[0]["user_id"], alice.to_string());
    assert_eq!(slots[0]["x"], 120.0);
    assert_eq!(slots[0]["y"], 340.0);
}

/// The Figma precedent the owner invoked by name: any editor may drag any
/// sticky note. A slot names the participant it represents, not who
/// arranged it, so bob may move alice's own screen-share tile with nothing
/// beyond ordinary `USE_CANVAS`.
#[tokio::test]
async fn anyone_with_use_canvas_may_move_anyone_elses_slot() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-anyone");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    let (_access, _ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_access, _bob_ticket, _bob) = user_ticket(&store, "bob").await;

    let response = http::router(state_for(&store))
        .oneshot(put_slot_request(
            channel,
            &bob_access,
            "screen",
            alice,
            screen_body(10.0, 20.0),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let json: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["user_id"], alice.to_string());
}

/// `USE_CANVAS` gates this route exactly as it gates a real object's move -
/// mutation-tested: dropping the permission check in
/// `http/canvas_media_slots.rs::upsert` fails exactly this test.
#[tokio::test]
async fn a_member_denied_use_canvas_is_forbidden() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-denied");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    let (_access, _ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (carol_access, _ticket, carol) = user_ticket(&store, "carol").await;
    store
        .set_member_overwrite(channel, carol, Permissions::NONE, Permissions::USE_CANVAS)
        .await
        .unwrap();

    let response = http::router(state_for(&store))
        .oneshot(put_slot_request(
            channel,
            &carol_access,
            "camera",
            carol,
            screen_body(0.0, 0.0),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// The write path's own direct timeout check, the same one
/// `placeCanvasObject` uses - mutation-tested: dropping `timed_out_until`
/// from `upsert` fails exactly this test.
#[tokio::test]
async fn a_timed_out_member_may_not_move_a_slot() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-timeout");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    let (_access, _ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_access, _ticket, bob) = user_ticket(&store, "bob").await;
    store
        .set_member_timeout(bob, chrono_now_plus_ms(60_000), None, alice)
        .await
        .unwrap();

    let response = http::router(state_for(&store))
        .oneshot(put_slot_request(
            channel,
            &bob_access,
            "camera",
            bob,
            screen_body(0.0, 0.0),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// Every successful move publishes live, unconditionally - there is no
/// idempotency-by-id to dedupe against the way a placement has, so unlike
/// `placeCanvasObject` even a byte-identical repeat still fans out.
#[tokio::test]
async fn moving_a_slot_publishes_live_to_other_viewers() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-live");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    let state = state_for(&store);
    let (access, _ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let response = http::router(state.clone())
        .oneshot(put_slot_request(
            channel,
            &access,
            "camera",
            alice,
            screen_body(7.0, 8.0),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let frame = read_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "canvas.media_slot.changed");
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["kind"], "camera");
    assert_eq!(frame["user_id"], alice.to_string());
    assert_eq!(frame["x"], 7.0);
    assert_eq!(frame["y"], 8.0);
    assert_eq!(frame["locked"], false);
    assert_eq!(frame["sent_to_back"], false);
}

/// The concurrency question the reversal's own scope named directly: two
/// viewers racing to touch the same participant's slot for the first time
/// must not create two rows. Mutation-tested: replacing the upsert's
/// `ON CONFLICT ... DO UPDATE` with a plain `INSERT` in
/// `store/canvas_media_slots.rs` fails this test - the second of the two
/// concurrent calls errors on the table's own primary key instead of
/// overwriting the first.
#[tokio::test]
async fn two_concurrent_first_touches_leave_exactly_one_row() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-race");
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

    let first = http::router(state.clone()).oneshot(put_slot_request(
        channel,
        &access,
        "camera",
        alice,
        screen_body(1.0, 1.0),
    ));
    let second = http::router(state.clone()).oneshot(put_slot_request(
        channel,
        &access,
        "camera",
        alice,
        screen_body(2.0, 2.0),
    ));
    let (first, second) = tokio::join!(first, second);
    assert_eq!(first.unwrap().status(), StatusCode::OK);
    assert_eq!(second.unwrap().status(), StatusCode::OK);

    let slots = store.list_canvas_media_slots(channel).await.unwrap().1;
    assert_eq!(slots.len(), 1, "a race must not create two rows");
}

/// The same out-of-world check a placement already makes, applied here too:
/// a slot is not exempt from the bounded world just because it carries no
/// drawn content.
#[tokio::test]
async fn an_out_of_bounds_slot_is_refused() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-bounds");
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

    let response = http::router(state_for(&store))
        .oneshot(put_slot_request(
            channel,
            &access,
            "camera",
            alice,
            screen_body(50_000_000.0, 0.0),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// Account deletion removes a departed member's own slots outright, since a
/// slot names the participant it represents and there is nobody left to
/// name once that account is gone - mutation-tested: dropping the
/// `DELETE FROM canvas_media_slots` line in `account_deletion.rs` fails
/// exactly this test.
#[tokio::test]
async fn deleting_an_account_removes_its_slots() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-deletion");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    let (_access, _ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (_bob_access, _bob_ticket, bob) = user_ticket(&store, "bob").await;

    store
        .upsert_canvas_media_slot(
            channel,
            bob,
            slimm_server::store::MediaSlotKind::Camera,
            (0.0, 0.0, 140.0, 140.0),
            false,
            false,
        )
        .await
        .unwrap();
    assert_eq!(
        store
            .list_canvas_media_slots(channel)
            .await
            .unwrap()
            .1
            .len(),
        1
    );

    store.delete_account(bob).await.unwrap();

    assert_eq!(
        store
            .list_canvas_media_slots(channel)
            .await
            .unwrap()
            .1
            .len(),
        0
    );
}

/// A `userId` with no matching account is refused by name rather than
/// falling through to `canvas_media_slots.user_id`'s own foreign key and
/// surfacing as a 500 - the same "a client-triggerable constraint violation
/// is a bug, not an acceptable error shape" this project has fixed before
/// (see `store/canvas.rs`'s own idempotency-lookup note). Mutation-tested:
/// dropping the existence check in `http/canvas_media_slots.rs::upsert`
/// fails exactly this test, turning it back into a 500.
#[tokio::test]
async fn a_slot_naming_no_real_user_is_not_found_rather_than_a_500() {
    let (path, _guard) = crate::support::TestDbGuard::new("slimm-media-slot-no-such-user");
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
    let fake_user = UserId(uuid::Uuid::now_v7());

    let response = http::router(state_for(&store))
        .oneshot(put_slot_request(
            channel,
            &access,
            "camera",
            fake_user,
            screen_body(0.0, 0.0),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}
