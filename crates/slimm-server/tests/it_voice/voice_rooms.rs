// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Temporary voice rooms (decision 0065): a lobby makes one room per person,
//! the owner locks, caps and renames it, and an emptied room is removed.

use std::sync::{Arc, Mutex};

use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::Hub;
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tower::ServiceExt;

use crate::support;
use support::livekit_webhook::webhook_request;

type Present = Arc<Mutex<Vec<String>>>;
type Removed = Arc<Mutex<Vec<String>>>;

pub(super) const API_KEY: &str = "APItestkey";
pub(super) const API_SECRET: &str = "a-test-secret-of-at-least-32-characters";

pub(super) fn signed_webhook(body: &Value) -> Request<Body> {
    webhook_request(body.clone(), API_KEY, API_SECRET)
}

pub(super) struct World {
    pub(super) app: Router,
    pub(super) store: Store,
    pub(super) voice: VoiceService,
    pub(super) hub: Hub,
    pub(super) present: Present,
    pub(super) removed: Removed,
    pub(super) admin: String,
    pub(super) admin_id: String,
    pub(super) alice: (String, String),
    pub(super) bob: (String, String),
    pub(super) lobby: String,
    pub(super) _guard: support::TestDbGuard,
}

/// A LiveKit room service whose participant list is whatever `present` holds.
async fn fake_livekit(present: Present, removed: Removed) -> String {
    async fn list(State((present, _)): State<(Present, Removed)>) -> Json<Value> {
        let ids = present.lock().unwrap().clone();
        let participants: Vec<Value> = ids
            .into_iter()
            .map(|id| json!({ "identity": id, "name": id, "joined_at": 0, "tracks": [] }))
            .collect();
        Json(json!({ "participants": participants }))
    }
    async fn delete() -> Json<Value> {
        Json(json!({}))
    }
    async fn remove(
        State((_, removed)): State<(Present, Removed)>,
        Json(body): Json<Value>,
    ) -> Json<Value> {
        removed
            .lock()
            .unwrap()
            .push(body["identity"].as_str().unwrap_or_default().to_owned());
        Json(json!({}))
    }
    let router = Router::new()
        .route("/twirp/livekit.RoomService/ListParticipants", post(list))
        .route("/twirp/livekit.RoomService/DeleteRoom", post(delete))
        .route("/twirp/livekit.RoomService/RemoveParticipant", post(remove))
        .with_state((present, removed));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    format!("http://{addr}")
}

async fn session(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (token, account.id.to_string())
}

pub(super) async fn world(prefix: &str) -> World {
    let (path, guard) = support::TestDbGuard::new(prefix);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    let present: Present = Arc::default();
    let removed: Removed = Arc::default();
    let sfu = fake_livekit(present.clone(), removed.clone()).await;
    let voice = VoiceService::for_test(&sfu, API_KEY, API_SECRET);
    let hub = Hub::new();
    let app = support::app::builder(store.clone())
        .hub(hub.clone())
        .voice(voice.clone())
        .router();
    let (admin, admin_id) = session(&store, "owner").await;
    let alice = session(&store, "alice").await;
    let bob = session(&store, "bob").await;
    let mut w = World {
        app,
        store,
        voice,
        hub,
        present,
        removed,
        admin,
        admin_id,
        alice,
        bob,
        lobby: String::new(),
        _guard: guard,
    };
    let admin = w.admin.clone();
    let (status, lobby) = w
        .call(
            "POST",
            "/channels",
            &admin,
            json!({"name": "join-to-create", "kind": "voice"}),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{lobby}");
    w.lobby = lobby["id"].as_str().unwrap().to_owned();
    let uri = format!("/channels/{}", w.lobby);
    let (status, body) = w
        .call("PATCH", &uri, &admin, json!({"creates_rooms": true}))
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["creates_rooms"], true);
    w
}

impl World {
    pub(super) async fn call(
        &self,
        method: &str,
        uri: &str,
        token: &str,
        body: Value,
    ) -> (StatusCode, Value) {
        let mut builder = Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("Bearer {token}"));
        let request = if body.is_null() {
            builder.body(Body::empty()).unwrap()
        } else {
            builder = builder.header("content-type", "application/json");
            builder.body(Body::from(body.to_string())).unwrap()
        };
        let response = self.app.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    pub(super) async fn open_room(&self, token: &str) -> Value {
        let uri = format!("/channels/{}/voice/room", self.lobby);
        let (status, room) = self.call("POST", &uri, token, Value::Null).await;
        assert_eq!(status, StatusCode::OK, "{room}");
        room
    }

    pub(super) async fn token_status(&self, token: &str, channel: &str) -> StatusCode {
        let uri = format!("/channels/{channel}/voice/token");
        self.call("POST", &uri, token, Value::Null).await.0
    }

    pub(super) async fn listed(&self, token: &str, channel: &str) -> bool {
        let (_, list) = self.call("GET", "/channels", token, Value::Null).await;
        list.as_array()
            .unwrap()
            .iter()
            .any(|c| c["id"] == json!(channel))
    }

    pub(super) async fn remove_if_empty(&self, channel: &str) {
        let id = ChannelId(channel.parse().unwrap());
        slimm_server::room_cleanup::remove_if_empty(&self.store, &self.voice, &self.hub, id).await;
    }
}

#[tokio::test]
async fn a_lobby_makes_one_room_per_person_and_a_retry_returns_it() {
    let w = world("slimm-rooms-open").await;
    let room = w.open_room(&w.alice.0).await;
    assert_eq!(room["name"], "alice's room");
    assert_eq!(room["kind"], "voice");
    assert_eq!(room["room_owner_id"], json!(w.alice.1));
    assert_eq!(room["room_lobby_id"], json!(w.lobby));
    assert_eq!(room["room_locked"], false);
    assert_eq!(
        w.open_room(&w.alice.0).await["id"],
        room["id"],
        "one room each"
    );

    let other = w.open_room(&w.bob.0).await;
    assert_ne!(other["id"], room["id"]);
    assert!(w.listed(&w.bob.0, room["id"].as_str().unwrap()).await);

    let (_, list) = w.call("GET", "/channels", &w.alice.0, Value::Null).await;
    let row = |id: &Value| {
        list.as_array()
            .unwrap()
            .iter()
            .find(|c| &c["id"] == id)
            .unwrap()
            .clone()
    };
    let lobby_row = row(&json!(w.lobby));
    assert!(
        lobby_row.get("room_owner_id").is_none(),
        "a lobby is not a room"
    );
    assert!(lobby_row.get("room_lobby_id").is_none());
    assert_eq!(row(&room["id"])["room_lobby_id"], json!(w.lobby));
}

#[tokio::test]
async fn only_a_voice_channel_that_is_not_a_room_can_make_rooms() {
    let w = world("slimm-rooms-voice-only").await;
    let (_, text) = w
        .call("POST", "/channels", &w.admin, json!({"name": "chat"}))
        .await;
    let uri = format!("/channels/{}", text["id"].as_str().unwrap());
    let (status, _) = w
        .call("PATCH", &uri, &w.admin, json!({"creates_rooms": true}))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let room = w.open_room(&w.alice.0).await;
    let uri = format!("/channels/{}", room["id"].as_str().unwrap());
    let (status, _) = w
        .call("PATCH", &uri, &w.admin, json!({"creates_rooms": true}))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "a room never makes rooms");

    let uri = format!("/channels/{}/voice/room", text["id"].as_str().unwrap());
    let (status, _) = w.call("POST", &uri, &w.alice.0, Value::Null).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "not a lobby");
}

#[tokio::test]
async fn a_lobby_can_be_created_in_one_call_and_never_as_text() {
    let w = world("slimm-rooms-create").await;
    let body = json!({"name": "lobby", "kind": "voice", "creates_rooms": true});
    let (status, lobby) = w.call("POST", "/channels", &w.admin, body).await;
    assert_eq!(status, StatusCode::OK, "{lobby}");
    assert_eq!(lobby["creates_rooms"], true);
    let uri = format!("/channels/{}/voice/room", lobby["id"].as_str().unwrap());
    let (status, room) = w.call("POST", &uri, &w.alice.0, Value::Null).await;
    assert_eq!(status, StatusCode::OK, "{room}");
    assert_eq!(room["room_lobby_id"], lobby["id"]);

    let body = json!({"name": "chat", "creates_rooms": true});
    let (status, _) = w.call("POST", "/channels", &w.admin, body).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn the_owner_renames_locks_and_caps_their_room_and_nobody_else_can() {
    let w = world("slimm-rooms-owner").await;
    let room = w.open_room(&w.alice.0).await;
    let uri = format!("/channels/{}/room", room["id"].as_str().unwrap());

    let body = json!({"name": "late night", "locked": true, "user_limit": 4});
    let (status, updated) = w.call("PATCH", &uri, &w.alice.0, body).await;
    assert_eq!(status, StatusCode::OK, "{updated}");
    assert_eq!(updated["name"], "late night");
    assert_eq!(updated["room_locked"], true);
    assert_eq!(updated["user_limit"], 4);

    let (status, _) = w
        .call("PATCH", &uri, &w.bob.0, json!({"locked": false}))
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = w
        .call("PATCH", &uri, &w.admin, json!({"locked": false}))
        .await;
    assert_eq!(status, StatusCode::OK, "a channel manager can too");

    let (status, _) = w
        .call("PATCH", &uri, &w.alice.0, json!({"user_limit": 100}))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_lock_and_a_limit_turn_away_new_people_but_never_the_owner_or_someone_inside() {
    let w = world("slimm-rooms-join").await;
    let room = w.open_room(&w.alice.0).await;
    let id = room["id"].as_str().unwrap().to_owned();
    let uri = format!("/channels/{id}/room");
    w.call("PATCH", &uri, &w.alice.0, json!({"locked": true}))
        .await;

    assert_eq!(w.token_status(&w.bob.0, &id).await, StatusCode::CONFLICT);
    assert_eq!(w.token_status(&w.alice.0, &id).await, StatusCode::OK);
    w.present.lock().unwrap().push(w.bob.1.clone());
    assert_eq!(
        w.token_status(&w.bob.0, &id).await,
        StatusCode::OK,
        "someone already in the call can rejoin"
    );

    w.present.lock().unwrap().clear();
    w.call(
        "PATCH",
        &uri,
        &w.alice.0,
        json!({"locked": false, "user_limit": 1}),
    )
    .await;
    w.present.lock().unwrap().push(w.alice.1.clone());
    assert_eq!(
        w.token_status(&w.bob.0, &id).await,
        StatusCode::CONFLICT,
        "full"
    );
    w.present.lock().unwrap().clear();
    assert_eq!(w.token_status(&w.bob.0, &id).await, StatusCode::OK);
}

#[tokio::test]
async fn a_room_copies_its_lobbys_audience() {
    let w = world("slimm-rooms-audience").await;
    let (_, roles) = w.call("GET", "/roles", &w.admin, Value::Null).await;
    let everyone = roles
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["is_everyone"] == json!(true))
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let view_connect = Permissions::VIEW_CHANNEL.union(Permissions::CONNECT).bits();
    let body = json!({"overwrites": [
        {"kind": "role", "id": everyone, "allow": 0, "deny": Permissions::VIEW_CHANNEL.bits()},
        {"kind": "member", "id": w.alice.1, "allow": view_connect, "deny": 0},
    ]});
    let uri = format!("/channels/{}/overwrites", w.lobby);
    let (status, body) = w.call("PUT", &uri, &w.admin, body).await;
    assert_eq!(status, StatusCode::OK, "{body}");

    let room = w.open_room(&w.alice.0).await;
    let id = room["id"].as_str().unwrap();
    assert!(w.listed(&w.alice.0, id).await);
    assert!(
        !w.listed(&w.bob.0, id).await,
        "bob cannot see the lobby, so not its rooms"
    );
    let uri = format!("/channels/{}/voice/room", w.lobby);
    assert_eq!(
        w.call("POST", &uri, &w.bob.0, Value::Null).await.0,
        StatusCode::FORBIDDEN
    );
}

#[tokio::test]
async fn a_message_can_be_sent_in_a_temporary_room() {
    let w = world("slimm-rooms-send").await;
    let room = w.open_room(&w.alice.0).await;
    let uri = format!("/channels/{}/messages", room["id"].as_str().unwrap());
    let body = json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hello room" });
    let (status, sent) = w.call("POST", &uri, &w.alice.0, body).await;
    assert_eq!(status, StatusCode::OK, "{sent}");
}

#[tokio::test]
async fn concurrent_open_room_calls_for_one_owner_make_one_room() {
    let w = world("slimm-rooms-concurrent").await;
    let uri = format!("/channels/{}/voice/room", w.lobby);
    let calls = (0..8).map(|_| {
        let app = w.app.clone();
        let (uri, token) = (uri.clone(), w.alice.0.clone());
        tokio::spawn(async move {
            let request = Request::builder()
                .method("POST")
                .uri(uri)
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap();
            let response = app.oneshot(request).await.unwrap();
            let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap();
            serde_json::from_slice::<Value>(&bytes).unwrap()["id"].clone()
        })
    });
    let ids = futures_util::future::join_all(calls).await;
    let first = ids[0].as_ref().unwrap().clone();
    assert!(ids.iter().all(|id| id.as_ref().unwrap() == &first));
    let (_, list) = w.call("GET", "/channels", &w.alice.0, Value::Null).await;
    let rooms = list
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["room_owner_id"] == json!(w.alice.1))
        .count();
    assert_eq!(rooms, 1);
}

#[tokio::test]
async fn a_timed_out_owner_cannot_edit_their_room_but_a_manager_can() {
    let w = world("slimm-rooms-timeout").await;
    let room = w.open_room(&w.alice.0).await;
    let uri = format!("/channels/{}/room", room["id"].as_str().unwrap());
    let admin = slimm_server::ids::UserId(w.admin_id.parse().unwrap());
    let alice = slimm_server::ids::UserId(w.alice.1.parse().unwrap());
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let until = now + 60_000;
    w.store
        .set_member_timeout(alice, until, None, admin)
        .await
        .unwrap();
    for body in [
        json!({"name": "loud"}),
        json!({"locked": true}),
        json!({"user_limit": 1}),
    ] {
        let (status, _) = w.call("PATCH", &uri, &w.alice.0, body).await;
        assert_eq!(status, StatusCode::FORBIDDEN);
    }
    let (status, _) = w
        .call("PATCH", &uri, &w.admin, json!({"name": "tidy"}))
        .await;
    assert_eq!(status, StatusCode::OK, "a channel manager still can");
}

#[tokio::test]
async fn a_no_op_patch_publishes_nothing_and_a_rename_leaves_the_permissions_epoch() {
    let w = world("slimm-rooms-quiet").await;
    let room = w.open_room(&w.alice.0).await;
    let uri = format!("/channels/{}/room", room["id"].as_str().unwrap());
    let mut events = w.hub.subscribe();
    let epoch = w.hub.permissions_epoch();

    let same = json!({"name": room["name"], "locked": false, "user_limit": 0});
    let (status, _) = w.call("PATCH", &uri, &w.alice.0, same).await;
    assert_eq!(status, StatusCode::OK);
    assert!(events.try_recv().is_err(), "nothing changed, nothing sent");

    let (status, _) = w
        .call("PATCH", &uri, &w.alice.0, json!({"name": "late night"}))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(events.try_recv().is_ok(), "a rename still reaches clients");
    assert_eq!(w.hub.permissions_epoch(), epoch, "and moves no permission");
}

#[tokio::test]
async fn a_joiner_past_the_user_limit_is_removed_once_the_sfu_admits_them() {
    let w = world("slimm-rooms-over-limit").await;
    let room = w.open_room(&w.alice.0).await;
    let id = room["id"].as_str().unwrap().to_owned();
    let uri = format!("/channels/{id}/room");
    w.call("PATCH", &uri, &w.alice.0, json!({"user_limit": 1}))
        .await;
    w.present
        .lock()
        .unwrap()
        .extend([w.alice.1.clone(), w.bob.1.clone()]);
    let joined = |who: &str| {
        json!({
            "event": "participant_joined",
            "room": { "name": format!("channel-{id}") },
            "participant": { "identity": who, "sid": format!("PA_{who}") },
        })
    };
    for who in [&w.alice.1, &w.bob.1] {
        let response = w.app.clone().oneshot(signed_webhook(&joined(who))).await;
        assert_eq!(response.unwrap().status(), StatusCode::NO_CONTENT);
    }
    support::wait::wait_until_async("the extra joiner to be removed", || async {
        w.removed.lock().unwrap().contains(&w.bob.1)
    })
    .await;
    assert!(!w.removed.lock().unwrap().contains(&w.alice.1));
}
