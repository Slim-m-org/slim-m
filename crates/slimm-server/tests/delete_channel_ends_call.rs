// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting a channel left any call inside it running.
//!
//! `delete_channel` soft-deletes the row and publishes `ChannelDeleted`, and
//! that was all: nobody was evicted and the SFU's room was never removed, so
//! a voice channel deleted mid-call kept hosting one. A LiveKit token is a
//! bearer credential this server cannot revoke, so the participants stayed
//! connected and anybody holding an unexpired token could rejoin a channel
//! that no longer existed.
//!
//! Drives a real `DELETE /channels/{id}` against a fake room service, the
//! `tests/member_moderation_evicts_dm_calls.rs` shape, so the proof is a
//! `DeleteRoom` call actually reaching the SFU rather than a status code.

use std::sync::{Arc, Mutex};

use axum::Router as SfuRouter;
use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use slimm_server::voice::{VoiceService, room_for_channel};
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

/// Records every `DeleteRoom` call, so a test asserts the SFU was actually
/// told rather than that the handler happened not to error.
#[derive(Clone, Default)]
struct RecordingRoomService {
    deleted: Arc<Mutex<Vec<Value>>>,
}

async fn delete_room(
    State(recorder): State<RecordingRoomService>,
    Json(body): Json<Value>,
) -> StatusCode {
    recorder.deleted.lock().unwrap().push(body);
    StatusCode::OK
}

async fn spawn_sfu(recorder: RecordingRoomService) -> String {
    let router = SfuRouter::new()
        .route("/twirp/livekit.RoomService/DeleteRoom", post(delete_room))
        .with_state(recorder);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    format!("http://{addr}")
}

fn app(store: Store, voice: VoiceService) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice,
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn request(method: &str, uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

/// An admin holding MANAGE_CHANNELS, which the bootstrap seeds.
async fn admin(store: &Store) -> String {
    let account = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

/// The deliverable: deleting a voice channel ends the call inside it, rather
/// than leaving it running in a channel that no longer exists.
#[tokio::test]
async fn deleting_a_voice_channel_ends_its_room() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = support::new_store("slimm-delete-channel-ends-call-test").await;
    let app = app(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );
    let admin_token = admin(&store).await;

    let channel = store.create_channel("lounge", "voice").await.unwrap();
    let response = app
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}", channel.id),
            &admin_token,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let deleted = recorder.deleted.lock().unwrap();
    assert_eq!(
        deleted.len(),
        1,
        "deleting a voice channel must end its room exactly once, got {deleted:?}"
    );
    assert_eq!(
        deleted[0]["room"].as_str(),
        Some(room_for_channel(channel.id).as_str()),
        "the room ended must be the deleted channel's own"
    );
}

/// Deliberately not gated on `kind == "voice"`. That filter is the shape this
/// project has already had to fix twice - once when a DM could hold a call,
/// once when threads arrived - each time because a routine only knew the
/// channel kinds that existed the week it was written. A room that never
/// existed costs one request to remove and changes nothing, so no future kind
/// can be forgotten here.
#[tokio::test]
async fn deleting_a_text_channel_ends_a_room_too_rather_than_trusting_its_kind() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = support::new_store("slimm-delete-channel-ends-call-test").await;
    let app = app(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );
    let admin_token = admin(&store).await;

    let channel = store.create_channel("notes", "text").await.unwrap();
    let response = app
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}", channel.id),
            &admin_token,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let deleted = recorder.deleted.lock().unwrap();
    assert_eq!(
        deleted.len(),
        1,
        "a text channel's deletion must still end a room, got {deleted:?}"
    );
}

/// A retry is the natural second chance when the first attempt could not
/// reach the SFU, so an already-deleted channel asks again rather than
/// assuming the first call landed.
#[tokio::test]
async fn an_idempotent_retry_asks_again_rather_than_assuming_the_first_landed() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = support::new_store("slimm-delete-channel-ends-call-test").await;
    let app = app(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );
    let admin_token = admin(&store).await;

    let channel = store.create_channel("lounge", "voice").await.unwrap();
    let uri = format!("/channels/{}", channel.id);
    for _ in 0..2 {
        let response = app
            .clone()
            .oneshot(request("DELETE", &uri, &admin_token))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    let deleted = recorder.deleted.lock().unwrap();
    assert_eq!(
        deleted.len(),
        2,
        "the retry must ask again, got {deleted:?}"
    );
}

/// A deployment with no SFU configured has no room to end, and must not have
/// its channel deletion fail on account of that.
#[tokio::test]
async fn a_deployment_with_no_sfu_still_deletes_the_channel() {
    let (store, _guard) = support::new_store("slimm-delete-channel-ends-call-test").await;
    let app = app(store.clone(), VoiceService::disabled());
    let admin_token = admin(&store).await;

    let channel = store.create_channel("lounge", "voice").await.unwrap();
    let response = app
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}", channel.id),
            &admin_token,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    let live = store.list_channels().await.unwrap();
    assert!(
        !live.iter().any(|c| c.id == channel.id),
        "the channel must still be deleted with no SFU configured"
    );
}
