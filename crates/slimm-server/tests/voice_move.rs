// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Moving someone between voice calls (decision 0071): the permission in
//! both channels, who may be moved where, the audit entry, and the frame
//! that reaches only the moved account.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use axum::{Json, Router};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::ChannelPatch;
use slimm_server::voice::{VoiceService, room_for_channel};
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

use support::app::{json_body, request_json};

type Rooms = Arc<Mutex<HashMap<String, Vec<String>>>>;

/// A room service whose rooms are whatever `rooms` holds, and which removes who it is told to.
async fn fake_livekit(rooms: Rooms) -> String {
    async fn list(State(rooms): State<Rooms>, Json(body): Json<Value>) -> Json<Value> {
        let room = body["room"].as_str().unwrap().to_owned();
        let ids = rooms
            .lock()
            .unwrap()
            .get(&room)
            .cloned()
            .unwrap_or_default();
        let participants: Vec<Value> = ids
            .into_iter()
            .map(|id| json!({ "identity": id, "name": id, "joined_at": 0, "tracks": [] }))
            .collect();
        Json(json!({ "participants": participants }))
    }
    async fn remove(State(rooms): State<Rooms>, Json(body): Json<Value>) -> Json<Value> {
        let room = body["room"].as_str().unwrap().to_owned();
        let identity = body["identity"].as_str().unwrap();
        if let Some(list) = rooms.lock().unwrap().get_mut(&room) {
            list.retain(|id| id != identity);
        }
        Json(json!({}))
    }
    let router = Router::new()
        .route("/twirp/livekit.RoomService/ListParticipants", post(list))
        .route("/twirp/livekit.RoomService/RemoveParticipant", post(remove))
        .with_state(rooms);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    format!("http://{addr}")
}

struct World {
    state: AppState,
    rooms: Rooms,
    admin: String,
    mover: (UserId, String),
    bob: (UserId, String),
    carol: (UserId, String),
    lobby: ChannelId,
    games: ChannelId,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-voice-move").await;
    let admin = support::app::register_token(&store, "owner").await;
    let movers = store
        .create_role("movers", Permissions::MOVE_MEMBERS, false)
        .await
        .unwrap();
    let mover = support::app::register_id_token(&store, "mover").await;
    store.assign_role(mover.0, movers).await.unwrap();
    let bob = support::app::register_id_token(&store, "bob").await;
    let carol = support::app::register_id_token(&store, "carol").await;
    let lobby = store.create_channel("lobby", "voice").await.unwrap().id;
    let games = store.create_channel("games", "voice").await.unwrap().id;
    let rooms: Rooms = Arc::default();
    let voice = VoiceService::for_test(
        &fake_livekit(rooms.clone()).await,
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    );
    let state = support::app::builder(store).voice(voice).build();
    let w = World {
        state,
        rooms,
        admin,
        mover,
        bob,
        carol,
        lobby,
        games,
        _guard: guard,
    };
    w.put(w.lobby, &[w.bob.0, w.carol.0]);
    w
}

impl World {
    fn put(&self, channel: ChannelId, who: &[UserId]) {
        self.rooms.lock().unwrap().insert(
            room_for_channel(channel),
            who.iter().map(ToString::to_string).collect(),
        );
    }

    fn present(&self, channel: ChannelId) -> Vec<String> {
        let rooms = self.rooms.lock().unwrap();
        rooms
            .get(&room_for_channel(channel))
            .cloned()
            .unwrap_or_default()
    }

    async fn move_to(
        &self,
        token: &str,
        from: ChannelId,
        who: UserId,
        to: ChannelId,
    ) -> StatusCode {
        self.move_raw(
            token,
            &from.to_string(),
            &who.to_string(),
            json!({ "to_channel_id": to.to_string() }),
        )
        .await
    }

    async fn move_raw(&self, token: &str, from: &str, who: &str, body: Value) -> StatusCode {
        let uri = format!("/channels/{from}/voice/participants/{who}/move");
        http::router(self.state.clone())
            .oneshot(request_json("POST", &uri, token, body))
            .await
            .unwrap()
            .status()
    }
}

#[tokio::test]
async fn a_mover_takes_someone_to_the_other_call_and_it_is_audited() {
    let w = world().await;
    let status = w.move_to(&w.mover.1, w.lobby, w.bob.0, w.games).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(w.present(w.lobby), vec![w.carol.0.to_string()]);

    let response = http::router(w.state.clone())
        .oneshot(support::app::request(
            "GET",
            "/reports/history?limit=20",
            Some(&w.admin),
            None,
        ))
        .await
        .unwrap();
    let history = json_body(response).await;
    let entry = history
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["action"] == "voice_move")
        .unwrap_or_else(|| panic!("no voice_move in {history}"));
    assert_eq!(entry["subject_id"], json!(w.bob.0.to_string()));
    assert_eq!(entry["actor_id"], json!(w.mover.0.to_string()));
    assert_eq!(entry["reason"], "lobby to games");
}

#[tokio::test]
async fn moving_needs_the_permission_in_both_channels() {
    let w = world().await;
    assert_eq!(
        w.move_to(&w.carol.1, w.lobby, w.bob.0, w.games).await,
        StatusCode::FORBIDDEN,
        "joining a call is not moving people out of it"
    );
    for denied in [w.lobby, w.games] {
        w.state
            .store
            .set_member_overwrite(
                denied,
                w.mover.0,
                Permissions::NONE,
                Permissions::MOVE_MEMBERS,
            )
            .await
            .unwrap();
        assert_eq!(
            w.move_to(&w.mover.1, w.lobby, w.bob.0, w.games).await,
            StatusCode::FORBIDDEN
        );
        w.state
            .store
            .set_member_overwrite(denied, w.mover.0, Permissions::NONE, Permissions::NONE)
            .await
            .unwrap();
    }
    assert_eq!(w.present(w.lobby).len(), 2, "nothing moved");
}

#[tokio::test]
async fn an_administrator_can_move_and_a_bot_can_hold_the_permission() {
    let w = world().await;
    assert_eq!(
        w.move_to(&w.admin, w.lobby, w.bob.0, w.games).await,
        StatusCode::NO_CONTENT
    );
    let admin_id = w
        .state
        .store
        .authenticate(&w.admin)
        .await
        .unwrap()
        .unwrap()
        .user_id;
    let bot = w
        .state
        .store
        .create_bot(
            "mover-bot",
            "mover-bot",
            Permissions::MOVE_MEMBERS,
            admin_id,
        )
        .await
        .unwrap();
    assert_eq!(
        w.move_to(&bot.token, w.lobby, w.carol.0, w.games).await,
        StatusCode::NO_CONTENT
    );
    assert!(w.present(w.lobby).is_empty());
}

#[tokio::test]
async fn someone_who_cannot_see_the_destination_is_not_moved() {
    let w = world().await;
    w.state
        .store
        .set_member_overwrite(
            w.games,
            w.bob.0,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    assert_eq!(
        w.move_to(&w.mover.1, w.lobby, w.bob.0, w.games).await,
        StatusCode::CONFLICT
    );
    assert!(w.present(w.lobby).contains(&w.bob.0.to_string()));
}

#[tokio::test]
async fn a_full_destination_refuses_the_move() {
    let w = world().await;
    w.state
        .store
        .update_channel_settings(
            w.games,
            ChannelPatch {
                user_limit: Some(1),
                ..ChannelPatch::default()
            },
        )
        .await
        .unwrap();
    w.put(w.games, &[w.mover.0]);
    assert_eq!(
        w.move_to(&w.mover.1, w.lobby, w.bob.0, w.games).await,
        StatusCode::CONFLICT
    );
    assert_eq!(
        w.move_to(&w.admin, w.lobby, w.bob.0, w.games).await,
        StatusCode::CONFLICT,
        "not even for an administrator"
    );
}

#[tokio::test]
async fn someone_who_is_not_in_the_call_cannot_be_moved() {
    let w = world().await;
    w.put(w.lobby, &[w.carol.0]);
    assert_eq!(
        w.move_to(&w.mover.1, w.lobby, w.bob.0, w.games).await,
        StatusCode::CONFLICT
    );
}

#[tokio::test]
async fn the_destination_must_be_another_voice_channel() {
    let w = world().await;
    let text = w
        .state
        .store
        .create_channel("chat", "text")
        .await
        .unwrap()
        .id;
    assert_eq!(
        w.move_to(&w.mover.1, w.lobby, w.bob.0, text).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        w.move_to(&w.mover.1, w.lobby, w.bob.0, w.lobby).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        w.move_raw(
            &w.mover.1,
            &w.lobby.to_string(),
            &w.bob.0.to_string(),
            json!({ "to_channel_id": "nope" })
        )
        .await,
        StatusCode::BAD_REQUEST
    );
}

#[tokio::test]
async fn only_the_moved_account_hears_about_it() {
    let w = world().await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = http::router(w.state.clone());
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    let mut bob = connect(&w, addr, &w.bob.1).await;
    let mut carol = connect(&w, addr, &w.carol.1).await;

    assert_eq!(
        w.move_to(&w.mover.1, w.lobby, w.bob.0, w.games).await,
        StatusCode::NO_CONTENT
    );

    let heard = frames(&mut bob).await;
    assert_eq!(heard.len(), 1, "{heard:?}");
    assert_eq!(heard[0]["from_channel_id"], json!(w.lobby.to_string()));
    assert_eq!(heard[0]["to_channel_id"], json!(w.games.to_string()));
    assert_eq!(heard[0]["to_channel_name"], "games");
    assert_eq!(heard[0]["moved_by_name"], "mover");
    assert!(frames(&mut carol).await.is_empty());
}

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(w: &World, addr: std::net::SocketAddr, token: &str) -> Client {
    let ctx = w.state.store.authenticate(token).await.unwrap().unwrap();
    let ticket = w.state.store.mint_ws_ticket(&ctx).await.unwrap().0;
    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();
    while let Some(Ok(WsMessage::Text(text))) = ws.next().await {
        let frame: Value = serde_json::from_str(text.as_str()).unwrap();
        if frame["type"] == "hello" {
            return ws;
        }
    }
    panic!("no hello ack");
}

/// Every `voice.moved` frame that arrives before the socket goes quiet.
async fn frames(ws: &mut Client) -> Vec<Value> {
    let mut found = Vec::new();
    while let Ok(Some(Ok(WsMessage::Text(text)))) =
        tokio::time::timeout(Duration::from_millis(500), ws.next()).await
    {
        let frame: Value = serde_json::from_str(text.as_str()).unwrap();
        if frame["type"] == "voice.moved" {
            found.push(frame);
        }
    }
    found
}
