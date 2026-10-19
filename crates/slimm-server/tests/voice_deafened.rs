// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A deafened listener is published as a participant attribute by the server,
//! because the room token withholds `canUpdateOwnMetadata` (which would also
//! let a client rewrite its own display name).

use std::sync::{Arc, Mutex};

use axum::Router as SfuRouter;
use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use axum::{Json, Router};
use serde_json::{Value, json};
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

use support::app::request_json;

#[derive(Clone, Default)]
struct RecordingRoomService {
    updates: Arc<Mutex<Vec<Value>>>,
}

async fn update_participant(
    State(recorder): State<RecordingRoomService>,
    Json(body): Json<Value>,
) -> StatusCode {
    recorder.updates.lock().unwrap().push(body);
    StatusCode::OK
}

async fn spawn_sfu(recorder: RecordingRoomService) -> String {
    let router = SfuRouter::new()
        .route(
            "/twirp/livekit.RoomService/UpdateParticipant",
            post(update_participant),
        )
        .with_state(recorder);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    format!("http://{addr}")
}

fn app(store: Store, voice: VoiceService) -> Router {
    support::app::builder(store).voice(voice).router()
}

async fn put_deafened(app: Router, channel: &str, token: &str, body: Value) -> StatusCode {
    let uri = format!("/channels/{channel}/voice/deafened");
    app.oneshot(request_json("PUT", &uri, token, body))
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn deafening_sets_the_attribute_and_undeafening_clears_it() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = support::new_store("slimm-voice-deafened-test").await;
    let alice = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let token = store
        .open_session(alice.id, "cli")
        .await
        .unwrap()
        .access_token;
    let channel = store.create_channel("lounge", "voice").await.unwrap();
    let app = app(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );

    let on = put_deafened(
        app.clone(),
        &channel.id.to_string(),
        &token,
        json!({"deafened": true}),
    )
    .await;
    let off = put_deafened(
        app,
        &channel.id.to_string(),
        &token,
        json!({"deafened": false}),
    )
    .await;

    assert_eq!(on, StatusCode::NO_CONTENT);
    assert_eq!(off, StatusCode::NO_CONTENT);
    let updates = recorder.updates.lock().unwrap();
    assert_eq!(updates.len(), 2);
    assert_eq!(updates[0]["room"], format!("channel-{}", channel.id));
    assert_eq!(updates[0]["identity"], alice.id.to_string());
    assert_eq!(updates[0]["attributes"]["deafened"], "true");
    assert_eq!(updates[1]["attributes"]["deafened"], "");
}

#[tokio::test]
async fn someone_who_cannot_connect_cannot_publish_a_state() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = support::new_store("slimm-voice-deafened-test").await;
    let alice = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let channel = store.create_channel("lounge", "voice").await.unwrap();
    let bob = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();
    let bob_token = store
        .open_session(bob.id, "cli")
        .await
        .unwrap()
        .access_token;
    store
        .set_member_overwrite(
            channel.id,
            bob.id,
            slimm_server::permissions::Permissions::NONE,
            slimm_server::permissions::Permissions::CONNECT,
        )
        .await
        .unwrap();
    let app = app(
        store,
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );

    let status = put_deafened(
        app,
        &channel.id.to_string(),
        &bob_token,
        json!({"deafened": true}),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(recorder.updates.lock().unwrap().is_empty());
}

#[tokio::test]
async fn no_voice_configured_is_a_501() {
    let (store, _guard) = support::new_store("slimm-voice-deafened-test").await;
    let alice = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let token = store
        .open_session(alice.id, "cli")
        .await
        .unwrap()
        .access_token;
    let channel = store.create_channel("lounge", "voice").await.unwrap();
    let app = support::app::builder(store).router();

    let status = put_deafened(
        app,
        &channel.id.to_string(),
        &token,
        json!({"deafened": true}),
    )
    .await;

    assert_eq!(status, StatusCode::NOT_IMPLEMENTED);
}
