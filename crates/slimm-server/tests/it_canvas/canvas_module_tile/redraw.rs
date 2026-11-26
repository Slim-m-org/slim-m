// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What stops a refreshing tile's redraw chain: the presser losing the channel, being timed out, or a cancelled press.

use crate::support::wasm_fixtures::canned_raw_wasm;
use axum::http::StatusCode;
use slimm_server::http::run_scene_refreshes;
use slimm_server::permissions::Permissions;
use slimm_server::store::OverwriteBatchEntry;

use super::{LIVE, Rig, now_ms, rig};

/// Presses a refreshing tile as Bob, then lets `change` take something from Bob.
async fn redraw_after(name: &str, change: impl AsyncFnOnce(&Rig)) -> (usize, usize) {
    let r = rig(name, canned_raw_wasm(LIVE)).await;
    let object = r.place_tile(&r.alice).await;
    assert_eq!(r.press(&r.bob, &object, "").await.0, StatusCode::OK);
    change(&r).await;
    let ran = run_scene_refreshes(&r.state, now_ms() + 4_000)
        .await
        .unwrap();
    let left = r
        .store
        .due_canvas_tile_refreshes(i64::MAX, 10)
        .await
        .unwrap()
        .len();
    (ran, left)
}

#[tokio::test]
async fn a_redraw_stops_when_the_presser_can_no_longer_see_the_channel() {
    let (ran, left) = redraw_after("slimm-canvas-tile-redraw-view", async |r| {
        let hide = OverwriteBatchEntry {
            target_type: "member",
            target_id: r.bob.id.0,
            allow: Permissions::NONE,
            deny: Permissions::VIEW_CHANNEL,
        };
        r.store
            .set_channel_overwrites_batch(r.channel, &[hide])
            .await
            .unwrap();
    })
    .await;

    assert_eq!((ran, left), (0, 0), "no run, and the chain is dropped");
}

#[tokio::test]
async fn a_redraw_stops_when_the_presser_is_timed_out() {
    let (ran, left) = redraw_after("slimm-canvas-tile-redraw-timeout", async |r| {
        let until = now_ms() + 3_600_000;
        let by = r.alice.id;
        r.store
            .set_member_timeout(r.bob.id, until, None, by)
            .await
            .unwrap();
    })
    .await;

    assert_eq!((ran, left), (0, 0), "no run, and the chain is dropped");
}

#[tokio::test]
async fn a_running_chain_cannot_revive_one_a_press_just_cancelled() {
    let r = rig("slimm-canvas-tile-redraw-revive", canned_raw_wasm(LIVE)).await;
    let object = r.place_tile(&r.alice).await;
    assert_eq!(r.press(&r.bob, &object, "").await.0, StatusCode::OK);
    let object_id = slimm_server::ids::CanvasObjectId(object.parse().unwrap());
    let until = now_ms() + 60_000;
    r.store.clear_canvas_tile_refresh(object_id).await.unwrap();

    r.store
        .schedule_canvas_tile_refresh(object_id, (now_ms(), until), false)
        .await
        .unwrap();

    let due = r.store.due_canvas_tile_refreshes(i64::MAX, 10).await;
    assert!(due.unwrap().is_empty());
}
