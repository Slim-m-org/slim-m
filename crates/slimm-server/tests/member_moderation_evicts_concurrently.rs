// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A timeout evicts the member from every voice room, several at a time rather
//! than one SFU round trip after another, and never more at once than the cap.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use axum::Router;
use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use serde_json::json;
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

use support::app::request_authed as request;

const ROOMS: usize = 12;

#[derive(Clone, Default)]
struct Flight {
    now: Arc<AtomicUsize>,
    peak: Arc<AtomicUsize>,
    calls: Arc<AtomicUsize>,
}

async fn remove_participant(State(flight): State<Flight>) -> StatusCode {
    let now = flight.now.fetch_add(1, Ordering::SeqCst) + 1;
    flight.peak.fetch_max(now, Ordering::SeqCst);
    tokio::time::sleep(Duration::from_millis(100)).await;
    flight.now.fetch_sub(1, Ordering::SeqCst);
    flight.calls.fetch_add(1, Ordering::SeqCst);
    StatusCode::OK
}

async fn spawn_slow_sfu(flight: Flight) -> String {
    let router = Router::new()
        .route(
            "/twirp/livekit.RoomService/RemoveParticipant",
            post(remove_participant),
        )
        .with_state(flight);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    format!("http://{addr}")
}

#[tokio::test]
async fn a_timeout_sweeps_the_rooms_concurrently_within_a_bound() {
    let flight = Flight::default();
    let sfu_url = spawn_slow_sfu(flight.clone()).await;
    let (store, _guard) = support::new_store("slimm-evict-concurrently").await;
    let voice = VoiceService::for_test(&sfu_url, "key", "a-secret-at-least-32-chars-long!");
    let app = support::app::builder(store.clone()).voice(voice).router();

    let admin = support::app::register_account(&store, "root").await;
    let bob = support::app::register_id(&store, "bob").await;
    for n in 0..ROOMS {
        store
            .create_channel(&format!("voice-{n}"), "voice")
            .await
            .unwrap();
    }

    let response = app
        .oneshot(request(
            "PUT",
            &format!("/members/{bob}/timeout"),
            &admin.token,
            Some(json!({ "duration_seconds": 300 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    assert_eq!(
        flight.calls.load(Ordering::SeqCst),
        ROOMS,
        "every room is swept"
    );
    let peak = flight.peak.load(Ordering::SeqCst);
    assert!(peak > 1, "rooms were swept one at a time (peak {peak})");
    assert!(peak <= 4, "the sweep exceeded its bound (peak {peak})");
}
