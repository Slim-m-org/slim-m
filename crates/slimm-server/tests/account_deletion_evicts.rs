// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting an account, by the member or by an administrator, must do what
//! removing a member does: announce `MemberRemoved` and drop them from every
//! voice room, because a LiveKit token is a bearer credential the server cannot
//! revoke. The control is a plain removal. The fake room service is the shape
//! `tests/member_moderation_evicts_dm_calls.rs` uses.

use std::sync::{Arc, Mutex};

use axum::Router as SfuRouter;
use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::{Event, Hub};
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

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

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-account-deletion-evicts-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn app(store: Store, voice: VoiceService) -> Router {
    app_with_hub(store, voice, Hub::new())
}

fn app_with_hub(store: Store, voice: VoiceService, hub: Hub) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub,
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

fn request(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

/// The admin who claims the deployment, plus two ordinary members.
async fn world(
    store: &Store,
) -> (
    String,
    slimm_server::ids::UserId,
    String,
    slimm_server::ids::UserId,
) {
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
    let hash = Auth::new(2)
        .unwrap()
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let bob = store.create_account("bob", "Bob", &hash).await.unwrap();
    let bob_token = store
        .open_session(bob.id, "cli")
        .await
        .unwrap()
        .access_token;
    (admin_token, admin.id, bob_token, bob.id)
}

fn drain_member_removed(
    rx: &mut tokio::sync::broadcast::Receiver<Event>,
    id: slimm_server::ids::UserId,
) -> bool {
    let mut seen = false;
    while let Ok(ev) = rx.try_recv() {
        let ev = match ev {
            Event::Stamped { event, .. } => *event,
            other => other,
        };
        if let Event::MemberRemoved(u) = ev {
            seen |= u == id;
        }
    }
    seen
}

#[tokio::test]
async fn control_removal_evicts_and_announces() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = new_store().await;
    let hub = Hub::new();
    let app = app_with_hub(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
        hub.clone(),
    );
    let (admin_token, _a, _bt, bob) = world(&store).await;
    let voice = store.create_channel("lounge", "voice").await.unwrap();
    let mut rx = hub.subscribe();
    let r = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bob}/removal"),
            &admin_token,
            Some(json!({})),
        ))
        .await
        .unwrap();
    assert!(r.status().is_success(), "{}", r.status());
    assert!(drain_member_removed(&mut rx, bob), "control: MemberRemoved");
    let removed = recorder.removed.lock().unwrap();
    assert!(
        removed
            .iter()
            .any(|c| c["room"] == format!("channel-{}", voice.id)
                && c["identity"] == bob.to_string()),
        "control: {removed:?}"
    );
}

#[tokio::test]
async fn admin_account_deletion_evicts_and_announces() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = new_store().await;
    let hub = Hub::new();
    let app = app_with_hub(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
        hub.clone(),
    );
    let (admin_token, _a, _bt, bob) = world(&store).await;
    let voice = store.create_channel("lounge", "voice").await.unwrap();
    let mut rx = hub.subscribe();
    let r = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{bob}/account"),
            &admin_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(r.status(), StatusCode::NO_CONTENT);
    let announced = drain_member_removed(&mut rx, bob);
    let removed = recorder.removed.lock().unwrap().clone();
    let evicted = removed
        .iter()
        .any(|c| c["room"] == format!("channel-{}", voice.id) && c["identity"] == bob.to_string());
    assert!(
        announced && evicted,
        "admin delete: MemberRemoved published={announced}, evicted from voice room={evicted}, RemoveParticipant calls={removed:?}"
    );
}

#[tokio::test]
async fn self_account_deletion_evicts_and_announces() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = new_store().await;
    let hub = Hub::new();
    let app = app_with_hub(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
        hub.clone(),
    );
    let (_at, _a, bob_token, bob) = world(&store).await;
    let voice = store.create_channel("lounge", "voice").await.unwrap();
    let mut rx = hub.subscribe();
    let r = app
        .clone()
        .oneshot(request(
            "DELETE",
            "/account",
            &bob_token,
            Some(json!({"password": "hunter2hunter2"})),
        ))
        .await
        .unwrap();
    assert_eq!(r.status(), StatusCode::NO_CONTENT);
    let announced = drain_member_removed(&mut rx, bob);
    let removed = recorder.removed.lock().unwrap().clone();
    let evicted = removed
        .iter()
        .any(|c| c["room"] == format!("channel-{}", voice.id) && c["identity"] == bob.to_string());
    assert!(
        announced && evicted,
        "self delete: MemberRemoved published={announced}, evicted from voice room={evicted}, RemoveParticipant calls={removed:?}"
    );
}

#[tokio::test]
async fn account_deletion_evicts_from_a_dm_call() {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, _guard) = new_store().await;
    let app = app(
        store.clone(),
        VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!"),
    );
    let (admin_token, admin, _bt, bob) = world(&store).await;
    let dm = store.open_dm(admin, bob).await.unwrap().id;
    let uri = format!("/members/{bob}/account");
    let r = app
        .clone()
        .oneshot(request("DELETE", &uri, &admin_token, None))
        .await
        .unwrap();
    assert_eq!(r.status(), StatusCode::NO_CONTENT);
    let removed = recorder.removed.lock().unwrap().clone();
    assert!(
        removed
            .iter()
            .any(|c| c["room"] == format!("channel-{dm}") && c["identity"] == bob.to_string()),
        "the DM room must be evicted too, got {removed:?}"
    );
}
