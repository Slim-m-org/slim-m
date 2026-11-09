// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A stand-in LiveKit room service on a loopback port, for tests that need the SFU's roster.

use std::sync::{Arc, Mutex};

use axum::extract::State;
use axum::routing::post;
use axum::{Json, Router};
use serde_json::{Value, json};
use slimm_server::ids::UserId;
use tokio::net::TcpListener;

type Roster = Arc<Mutex<Vec<Value>>>;

/// The session id [`RoomService`] reports for `user`, and webhooks should carry.
pub fn sid_of(user: UserId) -> String {
    format!("PA_{user}")
}

/// Answers every `ListParticipants` call with whoever was last put on the roster.
pub struct RoomService {
    pub url: String,
    roster: Roster,
}

impl RoomService {
    pub async fn spawn() -> Self {
        async fn answer(State(roster): State<Roster>) -> Json<Value> {
            Json(json!({ "participants": *roster.lock().unwrap() }))
        }
        let roster = Roster::default();
        let router = Router::new()
            .route("/twirp/livekit.RoomService/ListParticipants", post(answer))
            .with_state(roster.clone());
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        Self {
            url: format!("http://{addr}"),
            roster,
        }
    }

    /// Makes these users the room's participants.
    pub fn seat(&self, users: &[UserId]) {
        *self.roster.lock().unwrap() = users
            .iter()
            .map(|user| json!({ "identity": user.to_string(), "sid": sid_of(*user) }))
            .collect();
    }
}
