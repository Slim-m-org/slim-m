// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module's call scene (decision 0133): the noughts proof module draws a
//! `scene/1` from each board, and the host keeps it with that state, so the
//! answer, every frame and a late joiner's read carry the same scene at the same seq.

use axum::http::StatusCode;
use serde_json::{Value, json};

use crate::support;
use support::room_world::{RoomWorld, canned_room_wasm, noughts_wasm, room_world};
use support::ws::{connect, read_frame_of_type, serve};

/// The squares a scene still lets someone tap.
fn taps(scene: &Value) -> Vec<String> {
    scene["ops"]
        .as_array()
        .expect("a scene has ops")
        .iter()
        .filter_map(|op| op["tap"].as_str().map(str::to_owned))
        .collect()
}

async fn noughts(name: &str) -> RoomWorld {
    room_world(name, "noughts", noughts_wasm()).await
}

#[tokio::test]
async fn the_call_offers_the_scene_and_everyone_gets_it_with_the_state() {
    let r = noughts("slimm-scene-shared").await;
    let addr = serve(r.w.state.clone()).await;
    let (ava, ben) = (r.player("ava").await, r.player("ben").await);
    r.join_call(&ava);
    r.join_call(&ben);

    let (status, offer) = r.rooms_in(&ava, r.call).await;
    assert_eq!(status, StatusCode::OK, "{offer}");
    assert_eq!(
        offer["call_scenes"],
        json!([{ "module_id": "noughts", "name": "board", "title": "Noughts and crosses" }])
    );
    assert_eq!(offer["rooms"], json!([]));

    let (_, opened) = r.input(&ava, "").await;
    assert_eq!(opened["applied"], true, "{opened}");
    assert_eq!(opened["scene"]["$slim"], "scene/1");
    assert_eq!(taps(&opened["scene"]).len(), 9);

    let mut ava_ws = connect(addr, &ava.ticket).await;
    let (_, moved) = r.input(&ben, "4").await;
    assert_eq!(moved["seq"], 2, "{moved}");
    let frame = read_frame_of_type(&mut ava_ws, "module.room").await;
    assert_eq!(frame["seq"], 2);
    assert_eq!(frame["scene"], moved["scene"]);
    assert!(!taps(&frame["scene"]).contains(&"4".to_owned()));
    assert_eq!(frame["scene"]["status"], "O to move: tap a square to join");

    let late = r.room(&ava).await;
    assert_eq!(
        (late["seq"].clone(), late["scene"].clone()),
        (json!(2), moved["scene"].clone())
    );
}

#[tokio::test]
async fn a_refused_move_keeps_the_scene_it_was_refused_on() {
    let r = noughts("slimm-scene-refused").await;
    let ava = r.player("ava").await;
    r.join_call(&ava);
    let (_, first) = r.input(&ava, "0").await;
    let (_, refused) = r.input(&ava, "1").await;
    assert_eq!(refused["applied"], false);
    assert_eq!(refused["reason"], "not your turn");
    assert_eq!(refused["scene"], first["scene"]);
}

#[tokio::test]
async fn a_text_channel_offers_no_call_scene() {
    let r = noughts("slimm-scene-text").await;
    let ava = r.player("ava").await;
    let text = r.w.store.create_channel("games", "text").await.unwrap().id;
    let (status, body) = r.rooms_in(&ava, text).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["call_scenes"], json!([]));
}

#[tokio::test]
async fn a_scene_outside_scene_1_is_the_modules_failure() {
    let bad = json!({ "$slim": "room/1", "state": { "n": 1 }, "scene": { "ops": [] } });
    let r = room_world("slimm-scene-untagged", "rogue", canned_room_wasm(&bad)).await;
    let ava = r.player("ava").await;
    r.join_call(&ava);
    let (status, answer) = r.input(&ava, "go").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(answer["applied"], false, "{answer}");
    assert_eq!(answer["error"], "scene is not tagged scene/1");
    assert_eq!(r.room(&ava).await, Value::Null);
}
