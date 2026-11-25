// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Canvas channels and the voice canvas toggle (decision 0139): the kind, its two flags on create and update,
//! the computed `canvas_enabled` and `voice_enabled` on every channel shape, and `discard_canvas`.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{CanvasObjectId, ChannelId};
use slimm_server::permissions::Permissions;
use slimm_server::store::PlaceRequest;

use crate::support;
use support::app::TestApp;
use support::canvas::BoardChannels;

async fn create(app: &TestApp, body: Value) -> (StatusCode, Value) {
    app.call("POST", "/channels", &app.admin.token, Some(body))
        .await
}

async fn patch(app: &TestApp, channel: &str, body: Value) -> (StatusCode, Value) {
    app.call(
        "PATCH",
        &format!("/channels/{channel}"),
        &app.admin.token,
        Some(body),
    )
    .await
}

fn flags(body: &Value) -> (bool, bool) {
    (
        body["canvas_enabled"].as_bool().expect("canvas_enabled"),
        body["voice_enabled"].as_bool().expect("voice_enabled"),
    )
}

#[tokio::test]
async fn every_kind_reports_its_board_and_call() {
    let app = TestApp::start("slimm-canvas-kinds-dto").await;
    let cases = [
        (json!({ "name": "t" }), (false, false)),
        (json!({ "name": "v", "kind": "voice" }), (true, true)),
        (
            json!({ "name": "v-off", "kind": "voice", "canvas_enabled": false }),
            (false, true),
        ),
        (
            json!({ "name": "v-on", "kind": "voice", "canvas_enabled": true }),
            (true, true),
        ),
        (json!({ "name": "c", "kind": "canvas" }), (true, false)),
        (
            json!({ "name": "c-call", "kind": "canvas", "voice_enabled": true }),
            (true, true),
        ),
    ];
    for (body, expected) in cases {
        let (status, created) = create(&app, body.clone()).await;
        assert_eq!(status, StatusCode::OK, "{body}: {created}");
        assert_eq!(flags(&created), expected, "{body}");
    }
    let (_, listed) = app.call("GET", "/channels", &app.admin.token, None).await;
    let by_name = |name: &str| {
        listed
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["name"] == name)
            .unwrap_or_else(|| panic!("{name} is listed"))
            .clone()
    };
    assert_eq!(flags(&by_name("c-call")), (true, true));
    assert_eq!(by_name("c")["kind"], "canvas");
    assert_eq!(flags(&by_name("v-off")), (false, true));
    assert_eq!(flags(&by_name("general")), (false, false));
}

#[tokio::test]
async fn a_flag_on_the_wrong_kind_is_refused_on_create() {
    let app = TestApp::start("slimm-canvas-kinds-wrong").await;
    let refused = [
        json!({ "name": "a", "canvas_enabled": true }),
        json!({ "name": "b", "kind": "canvas", "canvas_enabled": true }),
        json!({ "name": "c", "voice_enabled": true }),
        json!({ "name": "d", "kind": "voice", "voice_enabled": true }),
        json!({ "name": "e", "kind": "canvas", "join_muted": true }),
        json!({ "name": "f", "kind": "canvas", "creates_rooms": true }),
        json!({ "name": "g", "kind": "board" }),
    ];
    for body in refused {
        let (status, error) = create(&app, body.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}: {error}");
    }
    let (status, ok) = create(
        &app,
        json!({ "name": "h", "canvas_enabled": false, "voice_enabled": false }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "false is a kind's own state: {ok}");
}

#[tokio::test]
async fn retrying_a_canvas_create_answers_the_stored_channel() {
    let app = TestApp::start("slimm-canvas-kinds-retry").await;
    let id = ChannelId::generate().to_string();
    let body = json!({ "id": id, "name": "designs", "kind": "canvas", "voice_enabled": true });
    let (first_status, first) = create(&app, body.clone()).await;
    let (second_status, second) = create(&app, body).await;
    assert_eq!(first_status, StatusCode::OK, "{first}");
    assert_eq!(second_status, StatusCode::OK, "{second}");
    assert_eq!(first["id"], second["id"]);
    assert_eq!(second["kind"], "canvas");
}

#[tokio::test]
async fn the_toggles_update_their_own_kind_and_nothing_else() {
    let app = TestApp::start("slimm-canvas-kinds-patch").await;
    let voice = app.store.create_voice_with_canvas("call").await.unwrap();
    let board = app
        .store
        .create_canvas_channel("board", false)
        .await
        .unwrap();
    let text = app.store.create_channel("words", "text").await.unwrap();

    let (status, off) = patch(
        &app,
        &voice.id.to_string(),
        json!({ "canvas_enabled": false }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{off}");
    assert_eq!(flags(&off), (false, true));
    let (_, on) = patch(
        &app,
        &voice.id.to_string(),
        json!({ "canvas_enabled": true }),
    )
    .await;
    assert_eq!(flags(&on), (true, true));

    let (status, call) = patch(
        &app,
        &board.id.to_string(),
        json!({ "voice_enabled": true }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{call}");
    assert_eq!(flags(&call), (true, true));

    let wrong = [
        (&text, json!({ "canvas_enabled": false })),
        (&board, json!({ "canvas_enabled": true })),
        (&board, json!({ "canvas_enabled": false })),
        (&text, json!({ "voice_enabled": false })),
        (&voice, json!({ "voice_enabled": true })),
        (&voice, json!({ "voice_enabled": false })),
        (&text, json!({ "discard_canvas": true })),
        (&board, json!({ "discard_canvas": true })),
    ];
    for (channel, body) in wrong {
        let (status, error) = patch(&app, &channel.id.to_string(), body.clone()).await;
        assert_eq!(
            status,
            StatusCode::BAD_REQUEST,
            "{body} on {}: {error}",
            channel.kind
        );
    }
    let (status, _) = patch(
        &app,
        &voice.id.to_string(),
        json!({ "discard_canvas": false }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "false is absent, so nothing to update"
    );
}

#[tokio::test]
async fn a_toggle_is_audited_by_field_name() {
    let app = TestApp::start("slimm-canvas-kinds-audit").await;
    let voice = app.store.create_voice_with_canvas("call").await.unwrap();
    let (status, _) = patch(
        &app,
        &voice.id.to_string(),
        json!({ "canvas_enabled": false }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, log) = app
        .call("GET", "/space/audit-log", &app.admin.token, None)
        .await;
    let row = log
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["action"] == "channel.update")
        .expect("the update is recorded");
    assert_eq!(row["detail"]["fields"], json!(["canvas_enabled"]));
}

#[tokio::test]
async fn a_room_copies_its_lobbys_canvas_and_a_lobby_toggle_reaches_the_lobby() {
    let app = TestApp::start("slimm-canvas-kinds-rooms").await;
    let (status, lobby) = create(
        &app,
        json!({ "name": "lobby", "kind": "voice", "creates_rooms": true, "canvas_enabled": true }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{lobby}");
    let lobby_row = app
        .store
        .channel(ChannelId(lobby["id"].as_str().unwrap().parse().unwrap()))
        .await
        .unwrap()
        .unwrap();
    let (room, _) = app
        .store
        .open_voice_room(&lobby_row, app.member.id, "room")
        .await
        .unwrap();
    assert!(room.canvas_open(), "the room inherits the lobby's board");
    let (status, off) = patch(
        &app,
        lobby["id"].as_str().unwrap(),
        json!({ "canvas_enabled": false }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{off}");
    assert!(!off["canvas_enabled"].as_bool().unwrap());
}

/// A manager who can see the channel and holds only the bits named, as a second member.
async fn manager_with(app: &TestApp, bits: Permissions) -> String {
    let role = slimm_server::ids::RoleId(
        app.create_role("channel-manager", bits.bits())
            .await
            .parse()
            .unwrap(),
    );
    app.store.assign_role(app.member.id, role).await.unwrap();
    app.member.token.clone()
}

async fn place_object(app: &TestApp, channel: &slimm_server::store::Channel, locked: bool) {
    let id = CanvasObjectId::generate();
    app.store
        .place_canvas_object(
            channel.id,
            app.admin.id,
            id,
            PlaceRequest {
                kind: "stroke",
                bounds: (0.0, 0.0, 10.0, 10.0),
                props: "{}",
                attachment: None,
            },
        )
        .await
        .expect("placed");
    if locked {
        app.store
            .set_canvas_object_lock(channel.id, id, app.admin.id, true, true)
            .await
            .expect("locked");
    }
}

#[tokio::test]
async fn discarding_a_hidden_board_removes_every_object_locked_ones_too() {
    let app = TestApp::start("slimm-canvas-kinds-discard").await;
    let voice = app.store.create_voice_with_canvas("call").await.unwrap();
    place_object(&app, &voice, false).await;
    place_object(&app, &voice, true).await;
    let id = voice.id.to_string();

    let (status, open) = patch(&app, &id, json!({ "discard_canvas": true })).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "an open board is cleared from the board: {open}"
    );
    assert_eq!(app.store.canvas_object_count(voice.id).await.unwrap(), 2);

    patch(&app, &id, json!({ "canvas_enabled": false })).await;
    let (status, done) = patch(&app, &id, json!({ "discard_canvas": true })).await;
    assert_eq!(status, StatusCode::OK, "{done}");
    assert!(!done["canvas_enabled"].as_bool().unwrap());
    assert_eq!(app.store.canvas_object_count(voice.id).await.unwrap(), 0);
}

#[tokio::test]
async fn discarding_in_one_request_with_the_toggle_off_works_and_with_it_on_does_not() {
    let app = TestApp::start("slimm-canvas-kinds-discard-together").await;
    let voice = app.store.create_voice_with_canvas("call").await.unwrap();
    place_object(&app, &voice, false).await;
    let id = voice.id.to_string();

    let (status, _) = patch(
        &app,
        &id,
        json!({ "canvas_enabled": true, "discard_canvas": true }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(app.store.canvas_object_count(voice.id).await.unwrap(), 1);

    let (status, done) = patch(
        &app,
        &id,
        json!({ "canvas_enabled": false, "discard_canvas": true }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{done}");
    assert_eq!(app.store.canvas_object_count(voice.id).await.unwrap(), 0);
}

#[tokio::test]
async fn discarding_needs_manage_canvas_and_changes_nothing_without_it() {
    let app = TestApp::start("slimm-canvas-kinds-discard-bits").await;
    let voice = app.store.create_voice_with_canvas("call").await.unwrap();
    place_object(&app, &voice, false).await;
    let id = voice.id.to_string();
    patch(&app, &id, json!({ "canvas_enabled": false })).await;

    let manager = manager_with(
        &app,
        Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
    )
    .await;
    let (status, _) = app
        .call(
            "PATCH",
            &format!("/channels/{id}"),
            &manager,
            Some(json!({ "discard_canvas": true, "topic": "changed" })),
        )
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(app.store.canvas_object_count(voice.id).await.unwrap(), 1);
    let unchanged = app.store.channel(voice.id).await.unwrap().unwrap();
    assert_eq!(
        unchanged.topic, None,
        "a refused discard writes no other field"
    );
}
