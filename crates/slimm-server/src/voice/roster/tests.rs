// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reading a LiveKit `ListParticipants` answer into [`RoomParticipant`]s, against a stand-in room service.

use axum::extract::State;
use axum::routing::post;
use axum::{Json, Router};
use serde_json::{Value, json};
use tokio::net::TcpListener;

use super::*;

/// Spawns a stand-in LiveKit room service on an ephemeral loopback port,
/// answering every `ListParticipants` call with a fixed status and body.
async fn spawn_room_service(status: axum::http::StatusCode, body: Value) -> String {
    #[derive(Clone)]
    struct Canned {
        status: axum::http::StatusCode,
        body: Value,
    }
    async fn answer(State(canned): State<Canned>) -> (axum::http::StatusCode, Json<Value>) {
        (canned.status, Json(canned.body))
    }
    let router = Router::new()
        .route("/twirp/livekit.RoomService/ListParticipants", post(answer))
        .with_state(Canned { status, body });
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    format!("http://{addr}")
}

fn service_at(url: &str) -> VoiceService {
    VoiceService::for_test(url, "APIkey", "a-secret-at-least-32-chars-long!")
}

async fn counting_room_service() -> (String, Arc<std::sync::atomic::AtomicUsize>) {
    let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counter = calls.clone();
    let router = Router::new().route(
        "/twirp/livekit.RoomService/ListParticipants",
        post(move || {
            counter.fetch_add(1, Ordering::SeqCst);
            async {
                tokio::time::sleep(Duration::from_millis(50)).await;
                Json(json!({ "participants": [] }))
            }
        }),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    (format!("http://{addr}"), calls)
}

#[tokio::test]
async fn polled_roster_reads_share_one_sfu_call_until_the_room_changes() {
    let (url, calls) = counting_room_service().await;
    let service = service_at(&url);
    let channel = ChannelId::generate();

    let reads = (0..5).map(|_| service.list_participants_shared(channel));
    for read in futures_util::future::join_all(reads).await {
        read.expect("the mock room service answered");
    }
    service.list_participants_shared(channel).await.unwrap();
    assert_eq!(
        calls.load(Ordering::SeqCst),
        1,
        "concurrent and repeated reads share a call"
    );

    service.roster_cache().invalidate(channel);
    service.list_participants_shared(channel).await.unwrap();
    assert_eq!(
        calls.load(Ordering::SeqCst),
        2,
        "a webhook event forces a fresh read"
    );
}

#[tokio::test]
async fn a_disabled_deployment_reports_unavailable_rather_than_calling_out() {
    let result = VoiceService::disabled()
        .list_participants(ChannelId::generate())
        .await;
    assert!(matches!(result, Err(VoiceError::Unavailable)));
}

#[tokio::test]
async fn participants_are_mapped_back_to_the_user_id_that_joined() {
    let alice = UserId::generate();
    let url = spawn_room_service(
        axum::http::StatusCode::OK,
        json!({
            "participants": [
                { "identity": alice.to_string(), "name": "Alice" },
            ]
        }),
    )
    .await;

    let participants = service_at(&url)
        .list_participants(ChannelId::generate())
        .await
        .expect("the mock room service answered");
    assert_eq!(
        participants,
        vec![RoomParticipant {
            user_id: alice,
            sid: String::new(),
            display_name: "Alice".to_owned(),
            is_sharing_screen: false,
            has_video: false,
            joined_at_ms: None,
            device_id: None,
            holder: None,
            is_active: false,
            is_muted: true,
            is_deafened: false,
        }]
    );
}

#[tokio::test]
async fn the_device_attribute_is_read_back() {
    let alice = UserId::generate();
    let url = spawn_room_service(
        axum::http::StatusCode::OK,
        json!({
            "participants": [
                {
                    "identity": alice.to_string(),
                    "name": "Alice",
                    "attributes": { (super::super::DEVICE_ATTRIBUTE): "device-7", "deafened": "" },
                },
            ]
        }),
    )
    .await;

    let participants = service_at(&url)
        .list_participants(ChannelId::generate())
        .await
        .expect("the mock room service answered");
    assert_eq!(participants[0].device_id.as_deref(), Some("device-7"));
}

#[tokio::test]
async fn a_screen_share_track_sets_is_sharing_screen_and_has_video() {
    let alice = UserId::generate();
    let url = spawn_room_service(
        axum::http::StatusCode::OK,
        json!({
            "participants": [
                {
                    "identity": alice.to_string(),
                    "name": "Alice",
                    "tracks": [
                        { "type": "VIDEO", "source": "SCREEN_SHARE" },
                        { "type": "AUDIO", "source": "SCREEN_SHARE_AUDIO" },
                    ],
                },
            ]
        }),
    )
    .await;

    let participants = service_at(&url)
        .list_participants(ChannelId::generate())
        .await
        .expect("the mock room service answered");
    assert_eq!(
        participants,
        vec![RoomParticipant {
            user_id: alice,
            sid: String::new(),
            display_name: "Alice".to_owned(),
            is_sharing_screen: true,
            has_video: true,
            joined_at_ms: None,
            device_id: None,
            holder: None,
            is_active: false,
            // An unmuted screen-share audio track counts, as it does for a client in the call.
            is_muted: false,
            is_deafened: false,
        }]
    );
}

#[tokio::test]
async fn the_join_time_reads_from_milliseconds_or_the_older_seconds_field() {
    let (alice, bob) = (UserId::generate(), UserId::generate());
    let url = spawn_room_service(
        axum::http::StatusCode::OK,
        json!({
            "participants": [
                { "identity": alice.to_string(), "joinedAtMs": "1700000000123", "joinedAt": "1700000000" },
                { "identity": bob.to_string(), "joined_at": 1700000005 },
            ]
        }),
    )
    .await;

    let participants = service_at(&url)
        .list_participants(ChannelId::generate())
        .await
        .expect("the mock room service answered");
    assert_eq!(participants[0].joined_at_ms, Some(1_700_000_000_123));
    assert_eq!(participants[1].joined_at_ms, Some(1_700_000_005_000));
}

#[tokio::test]
async fn a_camera_track_sets_has_video_without_screen_sharing() {
    let alice = UserId::generate();
    let url = spawn_room_service(
        axum::http::StatusCode::OK,
        json!({
            "participants": [
                {
                    "identity": alice.to_string(),
                    "name": "Alice",
                    "tracks": [{ "type": "VIDEO", "source": "CAMERA" }],
                },
            ]
        }),
    )
    .await;

    let participants = service_at(&url)
        .list_participants(ChannelId::generate())
        .await
        .expect("the mock room service answered");
    assert!(participants[0].has_video);
    assert!(!participants[0].is_sharing_screen);
}

#[tokio::test]
async fn a_room_that_was_never_created_is_empty_not_an_error() {
    let url = spawn_room_service(axum::http::StatusCode::NOT_FOUND, json!({})).await;
    let participants = service_at(&url)
        .list_participants(ChannelId::generate())
        .await
        .expect("a missing room is an empty room, not a failure");
    assert!(participants.is_empty());
}

#[tokio::test]
async fn an_identity_that_is_not_a_user_id_is_dropped_not_surfaced() {
    let url = spawn_room_service(
        axum::http::StatusCode::OK,
        json!({
            "participants": [
                { "identity": "not-a-uuid", "name": "Ghost" },
            ]
        }),
    )
    .await;
    let participants = service_at(&url)
        .list_participants(ChannelId::generate())
        .await
        .expect("a malformed identity must not fail the whole list");
    assert!(participants.is_empty());
}

#[tokio::test]
async fn an_upstream_failure_is_reported_rather_than_silently_empty() {
    let url = spawn_room_service(
        axum::http::StatusCode::INTERNAL_SERVER_ERROR,
        json!({ "error": "boom" }),
    )
    .await;
    let result = service_at(&url)
        .list_participants(ChannelId::generate())
        .await;
    assert!(matches!(result, Err(VoiceError::Internal(_))));
}

#[tokio::test]
async fn an_active_state_is_read_by_name_or_number() {
    let (alice, bob, carol) = (UserId::generate(), UserId::generate(), UserId::generate());
    let url = spawn_room_service(
        axum::http::StatusCode::OK,
        json!({
            "participants": [
                { "identity": alice.to_string(), "state": "ACTIVE" },
                { "identity": bob.to_string(), "state": 2 },
                { "identity": carol.to_string(), "state": "JOINED" },
            ]
        }),
    )
    .await;

    let participants = service_at(&url)
        .list_participants(ChannelId::generate())
        .await
        .expect("the mock room service answered");
    let active: Vec<bool> = participants.iter().map(|p| p.is_active).collect();
    assert_eq!(active, [true, true, false]);
}

#[tokio::test]
async fn muted_means_no_unmuted_audio_track_and_deafened_reads_the_attribute() {
    let (talking, muted, silent) = (UserId::generate(), UserId::generate(), UserId::generate());
    let url = spawn_room_service(
        axum::http::StatusCode::OK,
        json!({
            "participants": [
                {
                    "identity": talking.to_string(),
                    "tracks": [{ "type": "AUDIO", "source": "MICROPHONE", "muted": false }],
                },
                {
                    "identity": muted.to_string(),
                    "tracks": [
                        { "type": "AUDIO", "source": "MICROPHONE", "muted": true },
                        { "type": "VIDEO", "source": "CAMERA" },
                    ],
                    "attributes": { (super::super::DEAFENED_ATTRIBUTE): "true" },
                },
                { "identity": silent.to_string(), "tracks": [{ "type": "VIDEO", "source": "CAMERA" }] },
            ]
        }),
    )
    .await;

    let participants = service_at(&url)
        .list_participants(ChannelId::generate())
        .await
        .expect("the mock room service answered");
    let flags: Vec<(bool, bool)> = participants
        .iter()
        .map(|p| (p.is_muted, p.is_deafened))
        .collect();
    assert_eq!(flags, [(false, false), (true, true), (true, false)]);
}
