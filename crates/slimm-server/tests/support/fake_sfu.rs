// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A LiveKit room service that records the calls it receives, so a test proves a request reached the SFU,
//! and lists whoever a test seated in the room.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

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
    rooms: Arc<Mutex<HashMap<String, Vec<Value>>>>,
    listing_delay: Arc<Mutex<Duration>>,
}

impl RecordingRoomService {
    /// Makes these users the room's participants, each with a session id derived from its user id.
    pub fn seat(&self, users: &[UserId]) {
        *self.roster.lock().unwrap() = participants(users);
    }

    /// Seats these users in `room` alone; a room never seated this way answers with [`Self::seat`]'s list.
    pub fn seat_in(&self, room: &str, users: &[UserId]) {
        self.rooms
            .lock()
            .unwrap()
            .insert(room.to_owned(), participants(users));
    }

    /// Like [`Self::seat`], with each connection `ACTIVE`: signalling and media both up.
    pub fn seat_active(&self, users: &[UserId]) {
        *self.roster.lock().unwrap() = users
            .iter()
            .map(|user| {
                json!({ "identity": user.to_string(), "sid": format!("PA_{user}"), "state": "ACTIVE" })
            })
            .collect();
    }

    /// Answers `ListParticipants` with exactly these participant entries, tracks and attributes included.
    pub fn seat_listing(&self, participants: Vec<Value>) {
        *self.roster.lock().unwrap() = participants;
    }

    /// Makes every later `ListParticipants` answer only after `delay`, as a slow SFU would.
    pub fn delay_listing(&self, delay: Duration) {
        *self.listing_delay.lock().unwrap() = delay;
    }

    /// Like [`Self::seat`], with `sharers` publishing a screen share.
    pub fn seat_sharing(&self, users: &[UserId], sharers: &[UserId]) {
        *self.roster.lock().unwrap() = users
            .iter()
            .map(|user| {
                let tracks = if sharers.contains(user) {
                    json!([{ "source": "SCREEN_SHARE", "type": "VIDEO" }])
                } else {
                    json!([])
                };
                json!({ "identity": user.to_string(), "sid": format!("PA_{user}"), "tracks": tracks })
            })
            .collect();
    }

    /// Like [`Self::seat`], with the unix millisecond each user joined at.
    pub fn seat_joined(&self, users: &[(UserId, i64)]) {
        *self.roster.lock().unwrap() = users
            .iter()
            .map(|(user, at)| {
                json!({ "identity": user.to_string(), "sid": format!("PA_{user}"), "joined_at_ms": at })
            })
            .collect();
    }
}

fn participants(users: &[UserId]) -> Vec<Value> {
    users
        .iter()
        .map(|user| json!({ "identity": user.to_string(), "sid": format!("PA_{user}") }))
        .collect()
}

async fn list_participants(
    State(recorder): State<RecordingRoomService>,
    Json(body): Json<Value>,
) -> Json<Value> {
    let delay = *recorder.listing_delay.lock().unwrap();
    tokio::time::sleep(delay).await;
    let room = body["room"].as_str().unwrap_or_default();
    let seated = recorder.rooms.lock().unwrap().get(room).cloned();
    let present = seated.unwrap_or_else(|| recorder.roster.lock().unwrap().clone());
    Json(json!({ "participants": present }))
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
