// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A LiveKit room service that records the calls it receives, so a test proves a request reached the SFU,
//! and lists whoever a test seated in the room.

use std::sync::{Arc, Mutex};

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use serde_json::{Value, json};
use slimm_server::ids::UserId;
use tokio::net::TcpListener;

/// The bodies of each call kind, the bearer token that came with each `DeleteRoom`, and the
/// participants `ListParticipants` answers with.
#[derive(Clone, Default)]
pub struct RecordingRoomService {
    pub removed: Arc<Mutex<Vec<Value>>>,
    pub updates: Arc<Mutex<Vec<Value>>>,
    pub deleted: Arc<Mutex<Vec<Value>>>,
    pub bearers: Arc<Mutex<Vec<String>>>,
    roster: Arc<Mutex<Vec<Value>>>,
}

impl RecordingRoomService {
    /// Makes these users the room's participants, each with a session id derived from its user id.
    pub fn seat(&self, users: &[UserId]) {
        *self.roster.lock().unwrap() = users
            .iter()
            .map(|user| json!({ "identity": user.to_string(), "sid": format!("PA_{user}") }))
            .collect();
    }
}

async fn list_participants(State(recorder): State<RecordingRoomService>) -> Json<Value> {
    Json(json!({ "participants": *recorder.roster.lock().unwrap() }))
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
            "/twirp/livekit.RoomService/ListParticipants",
            post(list_participants),
        )
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
