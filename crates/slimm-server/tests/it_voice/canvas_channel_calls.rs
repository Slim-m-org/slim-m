// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Calls in canvas channels (decision 0139): `hosts_call()` decides who may get a token, a canvas call is moderated
//! like a voice call whatever its toggle says, turning the call off ends the room, and the data grant follows the board.

use axum::Router;
use axum::http::StatusCode;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use serde_json::{Value, json};
use slimm_server::store::Store;
use slimm_server::voice::{VoiceService, room_for_channel};
use tower::ServiceExt;

use crate::support;
use support::app::{json_body, request, request_authed, request_bare};
use support::canvas::BoardChannels;
use support::fake_sfu::{RecordingRoomService, spawn_sfu};

fn claims_of(token: &str) -> Value {
    let payload = token.split('.').nth(1).expect("a jwt has three parts");
    serde_json::from_slice(&BASE64URL.decode(payload).expect("base64url")).expect("json")
}

struct World {
    store: Store,
    router: Router,
    recorder: RecordingRoomService,
    admin: String,
    member: String,
    member_id: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let recorder = RecordingRoomService::default();
    let sfu = spawn_sfu(recorder.clone()).await;
    let (store, guard) = support::new_store("slimm-canvas-channel-calls").await;
    let voice = VoiceService::for_test(
        &sfu,
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    );
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let admin_token = store
        .open_session(admin.id, "cli")
        .await
        .unwrap()
        .access_token;
    let member = store
        .create_account("alice", "Alice", "not-a-real-hash")
        .await
        .unwrap();
    let member_token = store
        .open_session(member.id, "cli")
        .await
        .unwrap()
        .access_token;
    let router = support::app::builder(store.clone()).voice(voice).router();
    World {
        store,
        router,
        recorder,
        admin: admin_token,
        member: member_token,
        member_id: member.id.to_string(),
        _guard: guard,
    }
}

impl World {
    async fn token(&self, channel: impl std::fmt::Display) -> (StatusCode, Value) {
        let response = self
            .router
            .clone()
            .oneshot(request_bare(
                "POST",
                &format!("/channels/{channel}/voice/token"),
                Some(&self.admin),
            ))
            .await
            .unwrap();
        let status = response.status();
        (status, json_body(response).await)
    }
}

#[tokio::test]
async fn a_canvas_channel_gives_a_token_only_while_its_call_is_on() {
    let w = world().await;
    let with_call = w.store.create_canvas_channel("studio", true).await.unwrap();
    let without = w
        .store
        .create_canvas_channel("quiet-studio", false)
        .await
        .unwrap();

    let (status, body) = w.token(with_call.id).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["room"], format!("channel-{}", with_call.id));
    let (status, body) = w.token(without.id).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
}

#[tokio::test]
async fn the_data_grant_follows_the_board() {
    let w = world().await;
    let open = w.store.create_voice_with_canvas("loud").await.unwrap();
    let closed = w.store.create_channel("quiet", "voice").await.unwrap();
    let canvas = w.store.create_canvas_channel("studio", true).await.unwrap();
    let grant = |body: &Value| {
        claims_of(body["token"].as_str().unwrap())["video"]["canPublishData"].clone()
    };

    assert_eq!(grant(&w.token(open.id).await.1), true);
    assert_eq!(grant(&w.token(canvas.id).await.1), true);
    assert_eq!(
        grant(&w.token(closed.id).await.1),
        false,
        "a closed board hands out no data channel"
    );
}

#[tokio::test]
async fn a_timeout_removes_the_member_from_a_canvas_call_whatever_its_toggle_says() {
    let w = world().await;
    let on = w.store.create_canvas_channel("studio", true).await.unwrap();
    let off = w
        .store
        .create_canvas_channel("quiet-studio", false)
        .await
        .unwrap();

    let response = w
        .router
        .clone()
        .oneshot(request_authed(
            "PUT",
            &format!("/members/{}/timeout", w.member_id),
            &w.admin,
            Some(json!({ "duration_seconds": 300 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let removed = w.recorder.removed.lock().unwrap();
    for channel in [on.id, off.id] {
        assert!(
            removed
                .iter()
                .any(|call| call["room"] == room_for_channel(channel)
                    && call["identity"] == w.member_id),
            "a canvas channel's call is evicted from, call on or off: {removed:?}"
        );
    }
}

#[tokio::test]
async fn turning_the_call_off_ends_the_room_and_leaving_it_on_does_not() {
    let w = world().await;
    let channel = w.store.create_canvas_channel("studio", true).await.unwrap();
    let patch = |body: Value| {
        request_authed(
            "PATCH",
            &format!("/channels/{}", channel.id),
            &w.admin,
            Some(body),
        )
    };

    let response = w
        .router
        .clone()
        .oneshot(patch(json!({ "topic": "design" })))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert!(w.recorder.deleted.lock().unwrap().is_empty());

    let response = w
        .router
        .clone()
        .oneshot(patch(json!({ "voice_enabled": false })))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let deleted = w.recorder.deleted.lock().unwrap();
    assert_eq!(deleted.len(), 1, "{deleted:?}");
    assert_eq!(deleted[0]["room"], room_for_channel(channel.id));
}

#[tokio::test]
async fn join_notices_can_be_chosen_for_a_canvas_call_but_not_for_a_text_channel() {
    let w = world().await;
    let call = w.store.create_canvas_channel("studio", true).await.unwrap();
    let silent = w
        .store
        .create_canvas_channel("quiet-studio", false)
        .await
        .unwrap();
    let text = w.store.create_channel("words", "text").await.unwrap();
    let set = |channel: slimm_server::ids::ChannelId| {
        request(
            "PUT",
            &format!("/voice-notifications/channels/{channel}"),
            Some(&w.member),
            Some(json!({ "joins": "first", "streams": false })),
        )
    };
    for (channel, expected) in [
        (call.id, StatusCode::OK),
        (silent.id, StatusCode::BAD_REQUEST),
        (text.id, StatusCode::BAD_REQUEST),
    ] {
        let response = w.router.clone().oneshot(set(channel)).await.unwrap();
        assert_eq!(response.status(), expected, "{}", channel);
    }
}
