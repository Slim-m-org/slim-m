// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The closed-surface gate (decision 0139): every board route answers a channel with no board `403 canvas_off`,
//! after the view check, and an open board answers as it always did.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{CanvasObjectId, ChannelId, MessageId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, PlaceRequest};

use crate::support;
use support::app::TestApp;
use support::canvas::BoardChannels;

struct Route {
    method: &'static str,
    path: String,
    body: Option<Value>,
}

/// One request per board route group, shaped well enough to reach its handler.
fn board_routes(channel: ChannelId, object: CanvasObjectId, user: &str) -> Vec<Route> {
    let base = format!("/channels/{channel}/canvas");
    let place = |id: CanvasObjectId| json!({ "id": id.to_string(), "kind": "stroke", "x": 0, "y": 0, "w": 10, "h": 10, "props": {} });
    let route = |method, path: String, body| Route { method, path, body };
    vec![
        route(
            "GET",
            format!("{base}/objects?min_x=0&min_y=0&max_x=10&max_y=10"),
            None,
        ),
        route(
            "POST",
            format!("{base}/objects"),
            Some(place(CanvasObjectId::generate())),
        ),
        route(
            "POST",
            format!("{base}/objects/batch"),
            Some(json!({ "objects": [place(CanvasObjectId::generate())] })),
        ),
        route("GET", format!("{base}/ops?after_seq=0"), None),
        route("GET", format!("{base}/ops?after_seq=0&wait=1"), None),
        route("GET", format!("{base}/objects?ids={object}"), None),
        route("GET", format!("{base}/objects/{object}"), None),
        route("GET", format!("{base}/summary"), None),
        route(
            "POST",
            format!("{base}/ops"),
            Some(
                json!({ "id": CanvasObjectId::generate().to_string(), "kind": "clear", "before_seq": 0 }),
            ),
        ),
        route("GET", format!("{base}/object-locks"), None),
        route("PUT", format!("{base}/objects/{object}/lock"), None),
        route("DELETE", format!("{base}/objects/{object}/lock"), None),
        route("GET", format!("{base}/media-slots"), None),
        route(
            "PUT",
            format!("{base}/media-slots/camera/{user}"),
            Some(
                json!({ "x": 0, "y": 0, "w": 10, "h": 10, "locked": false, "sent_to_back": false }),
            ),
        ),
        route("GET", format!("{base}/objects/{object}/scene"), None),
        route(
            "POST",
            format!("{base}/objects/{object}/scene"),
            Some(json!({ "input": "" })),
        ),
        route("DELETE", format!("{base}/objects/{object}"), None),
    ]
}

fn refused_as_off(status: StatusCode, body: &Value) -> bool {
    status == StatusCode::FORBIDDEN && body["code"] == "canvas_off"
}

/// Every kind and flag combination, with whether its board is open.
struct Channels {
    text: ChannelId,
    thread: ChannelId,
    voice_off: ChannelId,
    voice_on: ChannelId,
    canvas: ChannelId,
    dm: ChannelId,
}

async fn channels(app: &TestApp) -> Channels {
    let text = app.store.create_channel("words", "text").await.unwrap();
    let voice_off = app.store.create_channel("quiet", "voice").await.unwrap();
    let voice_on = app.store.create_voice_with_canvas("loud").await.unwrap();
    let canvas = app
        .store
        .create_canvas_channel("board", true)
        .await
        .unwrap();
    let dm = app
        .store
        .open_dm(app.admin.id, app.member.id)
        .await
        .unwrap();
    let parent = MessageId::generate();
    app.store
        .send_message(NewMessage::plain(
            voice_on.id,
            app.admin.id,
            parent,
            "start a thread",
        ))
        .await
        .unwrap();
    let thread = app
        .store
        .open_thread(voice_on.id, parent)
        .await
        .unwrap()
        .channel;
    Channels {
        text: text.id,
        thread: thread.id,
        voice_off: voice_off.id,
        voice_on: voice_on.id,
        canvas: canvas.id,
        dm: dm.id,
    }
}

#[tokio::test]
async fn every_board_route_answers_a_closed_board_canvas_off_and_an_open_one_as_before() {
    let app = TestApp::start("slimm-canvas-gate-matrix").await;
    let c = channels(&app).await;
    let object = CanvasObjectId::generate();
    let user = app.admin.id.to_string();
    let cases = [
        ("text", c.text, false),
        ("thread", c.thread, false),
        ("voice off", c.voice_off, false),
        ("voice on", c.voice_on, true),
        ("canvas", c.canvas, true),
        ("dm", c.dm, true),
    ];
    for (label, channel, open) in cases {
        for route in board_routes(channel, object, &user) {
            let (status, body) = app
                .call(
                    route.method,
                    &route.path,
                    &app.admin.token,
                    route.body.clone(),
                )
                .await;
            let off = refused_as_off(status, &body);
            assert_eq!(
                off, !open,
                "{label}: {} {} answered {status} {body}",
                route.method, route.path
            );
        }
    }
}

#[tokio::test]
async fn a_channel_the_caller_cannot_see_answers_the_plain_403_before_the_surface() {
    let app = TestApp::start("slimm-canvas-gate-hidden").await;
    let hidden = app.store.create_channel("quiet", "voice").await.unwrap();
    app.store
        .set_member_overwrite(
            hidden.id,
            app.member.id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let (status, body) = app
        .call(
            "GET",
            &format!(
                "/channels/{}/canvas/objects?min_x=0&min_y=0&max_x=1&max_y=1",
                hidden.id
            ),
            &app.member.token,
            None,
        )
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(
        body.get("code").is_none(),
        "a hidden channel is not told apart from a closed one: {body}"
    );
}

#[tokio::test]
async fn a_closed_board_is_refused_before_the_draw_bit_and_a_spectator_still_reads_an_open_one() {
    let app = TestApp::start("slimm-canvas-gate-order").await;
    let voice = app.store.create_voice_with_canvas("loud").await.unwrap();
    app.store
        .set_member_overwrite(
            voice.id,
            app.member.id,
            Permissions::NONE,
            Permissions::USE_CANVAS,
        )
        .await
        .unwrap();
    let read = format!(
        "/channels/{}/canvas/objects?min_x=0&min_y=0&max_x=1&max_y=1",
        voice.id
    );
    let (status, _) = app.call("GET", &read, &app.member.token, None).await;
    assert_eq!(status, StatusCode::OK, "a spectator reads an open board");

    app.call(
        "PATCH",
        &format!("/channels/{}", voice.id),
        &app.admin.token,
        Some(json!({ "canvas_enabled": false })),
    )
    .await;
    let (status, body) = app.call("GET", &read, &app.member.token, None).await;
    assert!(refused_as_off(status, &body), "{status} {body}");
}

#[tokio::test]
async fn reopening_the_board_brings_everything_back() {
    let app = TestApp::start("slimm-canvas-gate-reopen").await;
    let voice = app.store.create_voice_with_canvas("loud").await.unwrap();
    app.store
        .place_canvas_object(
            voice.id,
            app.admin.id,
            CanvasObjectId::generate(),
            PlaceRequest {
                kind: "stroke",
                bounds: (0.0, 0.0, 10.0, 10.0),
                props: "{}",
                attachment: None,
            },
        )
        .await
        .unwrap();
    let id = voice.id.to_string();
    let read = format!("/channels/{id}/canvas/objects?min_x=0&min_y=0&max_x=100&max_y=100");
    let toggle = |on: bool| {
        let app = &app;
        let id = id.clone();
        async move {
            app.call(
                "PATCH",
                &format!("/channels/{id}"),
                &app.admin.token,
                Some(json!({ "canvas_enabled": on })),
            )
            .await;
        }
    };
    toggle(false).await;
    let (status, body) = app.call("GET", &read, &app.admin.token, None).await;
    assert!(refused_as_off(status, &body));
    toggle(true).await;
    let (status, body) = app.call("GET", &read, &app.admin.token, None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        body["objects"].as_array().map(Vec::len),
        Some(1),
        "nothing was deleted: {body}"
    );
}
