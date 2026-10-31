// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Lock and media-slot changes are ordered by one per-channel version, so a late
//! frame or an older read can be told from the newer state it would undo.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
use slimm_server::ids::{CanvasObjectId, ChannelId, UserId};
use slimm_server::store::{MediaSlotKind, PlaceRequest, Store};
use uuid::Uuid;

mod support;

use support::app::{call_as, request_json};
use support::ws::{connect, read_frame, serve, user_ticket_and_id};

struct World {
    store: Store,
    channel: ChannelId,
    admin: UserId,
    token: String,
    object: CanvasObjectId,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-canvas-state-version").await;
    let admin = support::app::register_account(&store, "alice").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let object = CanvasObjectId(Uuid::now_v7());
    store
        .place_canvas_object(
            channel,
            admin.id,
            object,
            PlaceRequest {
                kind: "note",
                bounds: (0.0, 0.0, 10.0, 10.0),
                props: "{}",
                attachment: None,
            },
        )
        .await
        .unwrap_or_else(|_| panic!("place refused"));
    World {
        store,
        channel,
        admin: admin.id,
        token: admin.token,
        object,
        _guard: guard,
    }
}

async fn flip(w: &World, locked: bool) -> Option<i64> {
    w.store
        .set_canvas_object_lock(w.channel, w.object, w.admin, true, locked)
        .await
        .unwrap_or_else(|_| panic!("lock refused"))
}

async fn put_slot(w: &World, x: f64) -> i64 {
    w.store
        .upsert_canvas_media_slot(
            w.channel,
            w.admin,
            MediaSlotKind::Camera,
            (x, 0.0, 200.0, 120.0),
            false,
            false,
        )
        .await
        .unwrap_or_else(|_| panic!("slot refused"))
        .1
}

#[tokio::test]
async fn lock_changes_and_slot_writes_share_one_rising_version() {
    let w = world().await;
    let lock = flip(&w, true).await.expect("a lock changes state");
    let slot = put_slot(&w, 1.0).await;
    let unlock = flip(&w, false).await.expect("an unlock changes state");
    assert!(lock < slot && slot < unlock, "{lock} {slot} {unlock}");
    assert_eq!(flip(&w, false).await, None, "a repeat changes nothing");
}

#[tokio::test]
async fn a_read_carries_the_version_it_was_taken_at() {
    let w = world().await;
    let (empty, _) = w.store.list_canvas_object_locks(w.channel).await.unwrap();
    assert_eq!(empty, 0);
    let lock = flip(&w, true).await.unwrap();
    let slot = put_slot(&w, 1.0).await;
    let (locks_at, locked) = w.store.list_canvas_object_locks(w.channel).await.unwrap();
    let (slots_at, _) = w.store.list_canvas_media_slots(w.channel).await.unwrap();
    assert_eq!(locked, vec![w.object]);
    assert_eq!((locks_at, slots_at), (slot, slot), "both see the head");
    assert!(lock < slot);
}

#[tokio::test]
async fn the_routes_and_frames_expose_the_version() {
    let w = world().await;
    let (viewer_ticket, _) = user_ticket_and_id(&w.store, "bob").await;
    let state = support::app::builder(w.store.clone())
        .hub(Hub::new())
        .build();
    let router = slimm_server::http::router(state.clone());
    let addr = serve(state).await;
    let mut ws = connect(addr, &viewer_ticket).await;
    let base = format!("/channels/{}/canvas", w.channel);

    let lock = request_json(
        "PUT",
        &format!("{base}/objects/{}/lock", w.object),
        &w.token,
        json!({}),
    );
    let response = tower::ServiceExt::oneshot(router.clone(), lock)
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    let frame = next_lock_frame(&mut ws).await;
    let (status, locks) = call_as(
        &router,
        "GET",
        &format!("{base}/object-locks"),
        &w.token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(locks["version"], frame["version"]);

    let slot_path = format!("{base}/media-slots/camera/{}", w.admin);
    let body = json!({ "x": 1.0, "y": 2.0, "w": 100.0, "h": 80.0, "locked": false, "sent_to_back": false });
    let (status, put) = call_as(&router, "PUT", &slot_path, &w.token, Some(body)).await;
    assert_eq!(status, StatusCode::OK);
    let version = put["version"]
        .as_i64()
        .expect("the write names its version");
    assert!(version > frame["version"].as_i64().unwrap());
    let (_, slots) = call_as(
        &router,
        "GET",
        &format!("{base}/media-slots"),
        &w.token,
        None,
    )
    .await;
    assert_eq!(slots["version"], version);
}

async fn next_lock_frame(ws: &mut support::ws::Client) -> Value {
    loop {
        let frame = read_frame(ws).await;
        if frame["type"] == "canvas.object.lock_changed" {
            return frame;
        }
    }
}
