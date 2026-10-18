// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Blocking has the same shape of gap `evict_from_voice` had, in a milder,
//! self-service form: `store/dms.rs`'s `BLOCKED_DENY` stops a new call being
//! started or joined in either direction, but nothing ended one already under
//! way when the block landed. The blocker can always hang up themselves, but
//! that is not an argument against the block itself taking effect, so
//! blocking now evicts the blocked party - never the blocker - from the DM
//! call the two of them share, if one is live.

use std::sync::{Arc, Mutex};

use axum::Router as SfuRouter;
use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use axum::{Json, Router};
use serde_json::Value;
use slimm_server::ids::UserId;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

use support::app::request_bearer as request;

/// Records every `RemoveParticipant` call it receives; see
/// `tests/voice_sweep.rs` for the shape this borrows.
#[derive(Clone, Default)]
struct RecordingRoomService {
    removed: Arc<Mutex<Vec<Value>>>,
}

async fn remove_participant(
    State(recorder): State<RecordingRoomService>,
    Json(body): Json<Value>,
) -> StatusCode {
    recorder.removed.lock().unwrap().push(body);
    StatusCode::OK
}

async fn spawn_sfu(recorder: RecordingRoomService) -> String {
    let router = SfuRouter::new()
        .route(
            "/twirp/livekit.RoomService/RemoveParticipant",
            post(remove_participant),
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

async fn register(store: &Store, username: &str) -> (UserId, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (account.id, token)
}

/// The deliverable: blocking someone you already share a live DM call with
/// ends their presence on it, without the blocker having to hang up first.
#[tokio::test]
async fn blocking_evicts_the_blocked_party_from_a_live_shared_call() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = support::new_store("slimm-block-evicts-call-test").await;
    let app = app(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );

    let (alice, alice_token) = register(&store, "alice").await;
    let (bob, _bob_token) = register(&store, "bob").await;
    let dm = store.open_dm(alice, bob).await.unwrap();

    let response = app
        .clone()
        .oneshot(request("POST", &format!("/blocks/{bob}"), &alice_token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let removed = recorder.removed.lock().unwrap();
    assert_eq!(
        removed.len(),
        1,
        "exactly one participant, the blocked one, must be evicted"
    );
    assert_eq!(removed[0]["room"], format!("channel-{}", dm.id));
    assert_eq!(removed[0]["identity"], bob.to_string());
}

/// The blocker is never the one evicted: they already hold the remedy of
/// hanging up themselves, and a block is not grounds to end the call for the
/// side who did not choose to.
#[tokio::test]
async fn blocking_never_evicts_the_blocker_themselves() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = support::new_store("slimm-block-evicts-call-test").await;
    let app = app(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );

    let (alice, alice_token) = register(&store, "alice").await;
    let (bob, _bob_token) = register(&store, "bob").await;
    store.open_dm(alice, bob).await.unwrap();

    app.clone()
        .oneshot(request("POST", &format!("/blocks/{bob}"), &alice_token))
        .await
        .unwrap();

    let removed = recorder.removed.lock().unwrap();
    assert!(
        removed
            .iter()
            .all(|call| call["identity"] != alice.to_string()),
        "the blocker must never be the one evicted, got {removed:?}"
    );
}

/// Blocking someone with no shared DM channel at all is a no-op on the call
/// side: there is nothing to evict from, and nothing tries.
#[tokio::test]
async fn blocking_with_no_shared_dm_evicts_nothing() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = support::new_store("slimm-block-evicts-call-test").await;
    let app = app(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );

    let (_alice, alice_token) = register(&store, "alice").await;
    let (bob, _bob_token) = register(&store, "bob").await;

    let response = app
        .clone()
        .oneshot(request("POST", &format!("/blocks/{bob}"), &alice_token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(recorder.removed.lock().unwrap().is_empty());
}
