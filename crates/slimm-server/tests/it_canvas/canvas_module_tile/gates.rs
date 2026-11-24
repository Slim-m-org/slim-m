// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who may press a module tile and how many redraw chains one presser may keep.

use axum::http::StatusCode;
use slimm_server::http::run_scene_refreshes;
use slimm_server::ids::CanvasObjectId;
use slimm_server::permissions::Permissions;
use slimm_server::store::OverwriteBatchEntry;
use support::wasm_fixtures::canned_raw_wasm;

use super::{LIVE, Person, Rig, now_ms, rig};
use crate::support;

async fn deny_bob(r: &Rig, deny: Permissions) {
    let entry = OverwriteBatchEntry {
        target_type: "member",
        target_id: r.bob.id.0,
        allow: Permissions::NONE,
        deny,
    };
    r.store
        .set_channel_overwrites_batch(r.channel, &[entry])
        .await
        .unwrap();
}

#[tokio::test]
async fn a_spectator_cannot_press_a_tile() {
    let r = rig("slimm-tile-press-spectator", canned_raw_wasm(LIVE)).await;
    let object = r.place_tile(&r.alice).await;
    deny_bob(&r, Permissions::USE_CANVAS).await;

    assert_eq!(r.press(&r.bob, &object, "").await.0, StatusCode::FORBIDDEN);
    assert_eq!(
        r.read_scene(&r.bob, &object).await.0,
        StatusCode::NOT_FOUND,
        "nothing was stored, and the read still works"
    );
}

#[tokio::test]
async fn a_timed_out_member_cannot_press_a_tile() {
    let r = rig("slimm-tile-press-timeout", canned_raw_wasm(LIVE)).await;
    let object = r.place_tile(&r.alice).await;
    let by = r.alice.id;
    r.store
        .set_member_timeout(r.bob.id, now_ms() + 3_600_000, None, by)
        .await
        .unwrap();

    assert_eq!(r.press(&r.bob, &object, "").await.0, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_redraw_stops_when_the_presser_loses_the_draw_bit() {
    let r = rig("slimm-tile-redraw-spectator", canned_raw_wasm(LIVE)).await;
    let object = r.place_tile(&r.alice).await;
    assert_eq!(r.press(&r.bob, &object, "").await.0, StatusCode::OK);
    deny_bob(&r, Permissions::USE_CANVAS).await;

    let ran = run_scene_refreshes(&r.state, now_ms() + 4_000)
        .await
        .unwrap();

    let left = r.store.due_canvas_tile_refreshes(i64::MAX, 10).await;
    assert_eq!((ran, left.unwrap().len()), (0, 0));
}

async fn press_new_tile(r: &Rig, who: &Person) -> String {
    let object = r.place_tile(who).await;
    assert_eq!(r.press(who, &object, "").await.0, StatusCode::OK);
    object
}

#[tokio::test]
async fn one_presser_keeps_a_bounded_number_of_chains() {
    let r = rig("slimm-tile-chain-cap", canned_raw_wasm(LIVE)).await;
    for _ in 0..6 {
        press_new_tile(&r, &r.bob).await;
    }

    let running = r.store.due_canvas_tile_refreshes(i64::MAX, 50).await;

    assert_eq!(running.unwrap().len(), 4);
}

#[tokio::test]
async fn a_pass_shares_its_redraws_between_pressers() {
    let r = rig("slimm-tile-chain-fair", canned_raw_wasm(LIVE)).await;
    for _ in 0..3 {
        press_new_tile(&r, &r.bob).await;
    }
    let alices = press_new_tile(&r, &r.alice).await;

    let first_two = r.store.due_canvas_tile_refreshes(i64::MAX, 2).await;

    let alices = CanvasObjectId(alices.parse().unwrap());
    assert!(first_two.unwrap().iter().any(|(id, ..)| *id == alices));
}
