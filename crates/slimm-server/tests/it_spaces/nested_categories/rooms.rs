// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A temporary room keeps its lobby's rows (decision 0065): every change that reaches
//! a lobby in a synced sub-category, copied down or edited directly, reaches its rooms.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use super::world::{NONE, VIEW, World, entry, has, overwrite_events, world};

struct Room {
    lobby: String,
    id: String,
    name: String,
}

/// A room lobby in minecraft, which follows gamers, and the gamer's room from it.
async fn gamer_room(w: &mut World) -> Room {
    let body = json!({"name": "mc-lobby", "kind": "voice", "category_id": w.minecraft});
    let lobby = w.ok("POST", "/channels", &w.admin, Some(body)).await["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let uri = format!("/channels/{lobby}");
    let rooms_on = json!({"creates_rooms": true});
    w.ok("PATCH", &uri, &w.admin, Some(rooms_on)).await;
    let uri = format!("/channels/{lobby}/voice/room");
    let room = w.ok("POST", &uri, &w.gamer.token, None).await;
    let room = Room {
        lobby,
        id: room["id"].as_str().unwrap().to_owned(),
        name: room["name"].as_str().unwrap().to_owned(),
    };
    assert!(has(&w.channel_names(&w.gamer.token).await, &room.name));
    w.drain();
    room
}

async fn channel_rows(w: &World, channel: &str) -> Value {
    let uri = format!("/channels/{channel}/overwrites");
    w.ok("GET", &uri, &w.admin, None).await["overwrites"].clone()
}

/// The room holds its lobby's rows, and the gamer sees it exactly when `visible`.
async fn assert_follows(w: &World, room: &Room, visible: bool) {
    assert_eq!(
        channel_rows(w, &room.id).await,
        channel_rows(w, &room.lobby).await,
        "the room holds its lobby's rows"
    );
    let channels = w.channel_names(&w.gamer.token).await;
    assert_eq!(has(&channels, &room.name), visible, "{channels:?}");
}

/// The last write published the room's change, naming the gamer when they could see it before.
fn assert_room_published(w: &mut World, room: &Room, gamer_saw_it: bool) {
    let events = overwrite_events(w);
    let before = events
        .get(&room.id)
        .expect("the room's change is published");
    assert_eq!(before.contains(&w.gamer.id), gamer_saw_it, "{events:?}");
}

#[tokio::test]
async fn narrowing_a_synced_sub_category_hides_the_rooms_of_its_lobbies() {
    let mut w = world("slimm-nested-room-sub").await;
    let room = gamer_room(&mut w).await;

    let cs_only = json!([
        entry("role", &w.gamer_role, NONE, NONE),
        entry("role", &w.cs_role, VIEW, NONE),
    ]);
    w.set_overwrites(&w.minecraft, cs_only).await;
    assert_room_published(&mut w, &room, true);
    assert_follows(&w, &room, false).await;
    let categories = w.category_names(&w.gamer.token).await;
    assert!(!has(&categories, "minecraft"), "{categories:?}");
    assert!(has(&w.channel_names(&w.cs.token).await, &room.name));

    let uri = format!("/categories/{}/overwrites/sync", w.minecraft);
    w.ok("POST", &uri, &w.admin, None).await;
    assert_room_published(&mut w, &room, false);
    assert_follows(&w, &room, true).await;
}

#[tokio::test]
async fn narrowing_the_parent_reaches_the_rooms_through_the_copy_down() {
    let mut w = world("slimm-nested-room-parent").await;
    let room = gamer_room(&mut w).await;

    let lock_out = json!([entry("role", &w.gamer_role, NONE, NONE)]);
    w.set_overwrites(&w.gamers, lock_out).await;
    assert_room_published(&mut w, &room, true);
    assert_follows(&w, &room, false).await;
    let categories = w.category_names(&w.gamer.token).await;
    for hidden in ["gamers", "minecraft"] {
        assert!(!has(&categories, hidden), "{categories:?}");
    }
}

#[tokio::test]
async fn every_direct_edit_of_a_lobby_reaches_its_rooms() {
    let mut w = world("slimm-nested-room-direct").await;
    let room = gamer_room(&mut w).await;
    let gamer_row = format!("/channels/{}/overwrites/role/{}", room.lobby, w.gamer_role);

    let deny = json!({"allow": 0, "deny": VIEW.bits()});
    w.ok("PUT", &gamer_row, &w.admin, Some(deny)).await;
    assert_room_published(&mut w, &room, true);
    assert_follows(&w, &room, false).await;

    let batch = format!("/channels/{}/overwrites", room.lobby);
    let allow = json!({"overwrites": [entry("role", &w.gamer_role, VIEW, NONE)]});
    w.ok("PUT", &batch, &w.admin, Some(allow)).await;
    assert_room_published(&mut w, &room, false);
    assert_follows(&w, &room, true).await;

    w.ok("DELETE", &gamer_row, &w.admin, None).await;
    assert_room_published(&mut w, &room, true);
    assert_follows(&w, &room, false).await;

    let sync = format!("/channels/{}/overwrites/sync", room.lobby);
    w.ok("POST", &sync, &w.admin, None).await;
    assert_room_published(&mut w, &room, false);
    assert_follows(&w, &room, true).await;
}

/// Every write a room's own rows could take, each of which a lobby write would undo.
fn own_row_writes(w: &World, room: &Room) -> Vec<(&'static str, String, Option<Value>)> {
    let quiet = Permissions::SEND_MESSAGES;
    let rows = format!("/channels/{}/overwrites", room.id);
    let row = |role: &str| format!("{rows}/role/{role}");
    let deny = json!({"allow": 0, "deny": quiet.bits()});
    let batch = json!({"overwrites": [entry("role", &w.cs_role, NONE, quiet)]});
    vec![
        ("PUT", row(&w.cs_role), Some(deny)),
        ("DELETE", row(&w.gamer_role), None),
        ("POST", format!("{rows}/sync"), None),
        ("PUT", rows, Some(batch)),
    ]
}

#[tokio::test]
async fn a_room_takes_no_overwrite_of_its_own_since_its_lobby_s_next_write_would_lift_it() {
    let mut w = world("slimm-nested-room-read-only").await;
    let room = gamer_room(&mut w).await;
    for (method, uri, body) in own_row_writes(&w, &room) {
        let (status, body) = w.call(method, &uri, &w.admin, body).await;
        assert_eq!(status, StatusCode::CONFLICT, "{method} {uri}: {body}");
    }
    let events = overwrite_events(&mut w);
    assert!(events.is_empty(), "{events:?}");
    assert_follows(&w, &room, true).await;
}

#[tokio::test]
async fn syncing_a_room_to_its_category_is_refused_so_it_keeps_its_lobby_s_rows() {
    let mut w = world("slimm-nested-room-own-sync").await;
    let room = gamer_room(&mut w).await;
    let gamer_row = format!("/channels/{}/overwrites/role/{}", room.lobby, w.gamer_role);
    let deny = json!({"allow": 0, "deny": VIEW.bits()});
    w.ok("PUT", &gamer_row, &w.admin, Some(deny)).await;
    assert_follows(&w, &room, false).await;
    w.drain();

    let sync = format!("/channels/{}/overwrites/sync", room.id);
    let (status, body) = w.call("POST", &sync, &w.admin, None).await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_follows(&w, &room, false).await;

    let neither = w.neither.id.to_string();
    let let_in = json!([entry("member", &neither, VIEW, NONE)]);
    w.set_overwrites(&w.minecraft, let_in).await;
    let events = overwrite_events(&mut w);
    assert!(!events.contains_key(&room.id), "{events:?}");
    assert_follows(&w, &room, false).await;
}
