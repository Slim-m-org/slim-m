// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A LiveKit room service that records the calls it receives, so a test proves a request reached the SFU.

use std::sync::{Arc, Mutex};

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use serde_json::Value;
use tokio::net::TcpListener;

/// The bodies of each call kind, and the bearer token that came with each `DeleteRoom`.
#[derive(Clone, Default)]
pub struct RecordingRoomService {
    pub removed: Arc<Mutex<Vec<Value>>>,
    pub updates: Arc<Mutex<Vec<Value>>>,
    pub deleted: Arc<Mutex<Vec<Value>>>,
    pub bearers: Arc<Mutex<Vec<String>>>,
}

async fn remove_participant(
    State(recorder): State<RecordingRoomService>,
    Json(body): Json<Value>,
) -> StatusCode {
    recorder.removed.lock().unwrap().push(body);
    StatusCode::OK
}

async fn update_participant(
    State(recorder): State<RecordingRoomService>,
    Json(body): Json<Value>,
) -> StatusCode {
    recorder.updates.lock().unwrap().push(body);
    StatusCode::OK
}

async fn delete_room(
    State(recorder): State<RecordingRoomService>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> StatusCode {
    let bearer = headers["authorization"].to_str().unwrap().to_owned();
    recorder.bearers.lock().unwrap().push(bearer);
    recorder.deleted.lock().unwrap().push(body);
    StatusCode::OK
}

/// Serves `recorder` on a free local port and returns its base URL.
pub async fn spawn_sfu(recorder: RecordingRoomService) -> String {
    let router = Router::new()
        .route(
            "/twirp/livekit.RoomService/RemoveParticipant",
            post(remove_participant),
        )
        .route(
            "/twirp/livekit.RoomService/UpdateParticipant",
            post(update_participant),
        )
        .route("/twirp/livekit.RoomService/DeleteRoom", post(delete_room))
        .with_state(recorder);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    format!("http://{addr}")
}
