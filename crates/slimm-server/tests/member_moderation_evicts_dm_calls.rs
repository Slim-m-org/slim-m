// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `evict_from_voice` (`http/members.rs`) was written three days before a DM
//! channel could hold a call at all, and nothing taught it about one once it
//! could: it only ever walked `voice`-kind channels. A member removed or
//! timed out stayed on a DM call with a third party they had just lost every
//! other right to reach. Drives the real store's `RemoveParticipant` call
//! against a fake room service, the `tests/voice_sweep.rs` shape, so the
//! proof is a call actually reaching the SFU rather than a status code.

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

use support::app::request_authed as request;

/// A room service that records every `RemoveParticipant` call it receives,
/// the same shape `tests/voice_sweep.rs` uses to prove eviction reaches the
/// SFU rather than only a code path that happens not to error.
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

/// The admin who claims the deployment, plus two ordinary members.
async fn people(store: &Store) -> (String, String, String, String) {
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

    let alice = store
        .create_account("alice", "Alice", "not-a-real-hash")
        .await
        .unwrap();
    let alice_token = store
        .open_session(alice.id, "cli")
        .await
        .unwrap()
        .access_token;

    let bob = store
        .create_account("bob", "Bob", "not-a-real-hash")
        .await
        .unwrap();

    (
        admin_token,
        alice.id.to_string(),
        alice_token,
        bob.id.to_string(),
    )
}

/// The deliverable: timing out a member who is on a DM call with a third
/// party ends that call for them immediately, not whenever their token
/// happens to lapse.
#[tokio::test]
async fn a_timeout_evicts_the_target_from_a_dm_call_they_are_on() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = support::new_store("slimm-moderation-evicts-dm-test").await;
    let app = app(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );

    let (admin_token, alice_id, alice_token, bob_id) = people(&store).await;
    let dm_channel_id = store
        .open_dm(
            slimm_server::ids::UserId(alice_id.parse().unwrap()),
            slimm_server::ids::UserId(bob_id.parse().unwrap()),
        )
        .await
        .unwrap()
        .id;
    let _ = alice_token;

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bob_id}/timeout"),
            &admin_token,
            Some(json!({ "duration_seconds": 300 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let removed = recorder.removed.lock().unwrap();
    assert!(
        removed.iter().any(|call| {
            call["room"] == format!("channel-{dm_channel_id}") && call["identity"] == bob_id
        }),
        "a RemoveParticipant call for the DM room must reach the SFU, got {removed:?}"
    );
}

/// Hiding a DM must not smuggle its call past moderation.
///
/// `DELETE /dms/{id}` is a sidebar-declutter preference, and
/// `list_dm_conversations` honours it by design. `evict_from_voice` used
/// that filtered list, so a member who hid the conversation while staying
/// connected to its call kept live audio after being timed out - one
/// ordinary request away from defeating moderation for anyone who saw it
/// coming. Eviction now reads every DM the target is party to.
#[tokio::test]
async fn hiding_a_dm_does_not_hide_its_call_from_a_timeout() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = support::new_store("slimm-moderation-evicts-dm-test").await;
    let app = app(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );

    let (admin_token, alice_id, _alice_token, bob_id) = people(&store).await;
    let alice = slimm_server::ids::UserId(alice_id.parse().unwrap());
    let bob = slimm_server::ids::UserId(bob_id.parse().unwrap());
    let dm_channel_id = store.open_dm(alice, bob).await.unwrap().id;

    // Bob hides the conversation while remaining on its call.
    store.hide_dm_conversation(bob, alice).await.unwrap();
    assert!(
        store
            .list_dm_conversations(bob)
            .await
            .unwrap()
            .iter()
            .all(|c| c.channel_id != dm_channel_id),
        "sanity: the hide really did take it out of bob's own sidebar list"
    );

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bob_id}/timeout"),
            &admin_token,
            Some(json!({ "duration_seconds": 300 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let removed = recorder.removed.lock().unwrap();
    assert!(
        removed.iter().any(|call| {
            call["room"] == format!("channel-{dm_channel_id}") && call["identity"] == bob_id
        }),
        "a hidden DM's call must still be evicted, got {removed:?}"
    );
}

/// The durable version of the same act: removing a member from the Space
/// must end their DM calls too, for the same reason a timeout must.
#[tokio::test]
async fn a_removal_evicts_the_target_from_a_dm_call_they_are_on() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = support::new_store("slimm-moderation-evicts-dm-test").await;
    let app = app(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );

    let (admin_token, alice_id, alice_token, bob_id) = people(&store).await;
    let dm_channel_id = store
        .open_dm(
            slimm_server::ids::UserId(alice_id.parse().unwrap()),
            slimm_server::ids::UserId(bob_id.parse().unwrap()),
        )
        .await
        .unwrap()
        .id;
    let _ = alice_token;

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bob_id}/removal"),
            &admin_token,
            Some(json!({})),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let removed = recorder.removed.lock().unwrap();
    assert!(
        removed.iter().any(|call| {
            call["room"] == format!("channel-{dm_channel_id}") && call["identity"] == bob_id
        }),
        "a RemoveParticipant call for the DM room must reach the SFU, got {removed:?}"
    );
}

/// A member with no DM channel at all costs nothing extra: `list_dm_conversations`
/// answers empty and only the deployment's `voice`-kind channels are walked, the
/// pre-existing behaviour for someone with no calls anywhere.
#[tokio::test]
async fn a_target_with_no_dms_is_evicted_with_no_extra_calls() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = support::new_store("slimm-moderation-evicts-dm-test").await;
    let app = app(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );

    let (admin_token, _alice_id, _alice_token, bob_id) = people(&store).await;

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bob_id}/timeout"),
            &admin_token,
            Some(json!({ "duration_seconds": 300 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    // bootstrap seeds no voice channel and bob has no DM, so nothing is evicted.
    assert!(recorder.removed.lock().unwrap().is_empty());
}
