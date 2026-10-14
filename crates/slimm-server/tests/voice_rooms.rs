// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Temporary voice rooms (decision 0065): a lobby makes one room per person,
//! the owner locks, caps and renames it, and an emptied room is removed.

use std::sync::{Arc, Mutex};

use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64STD;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

type Present = Arc<Mutex<Vec<String>>>;

const API_KEY: &str = "APItestkey";
const API_SECRET: &str = "a-test-secret-of-at-least-32-characters";

/// Signed the way LiveKit signs a webhook delivery; see live_voice_participant_events.rs.
fn signed_webhook(body: &Value) -> Request<Body> {
    let bytes = serde_json::to_vec(body).unwrap();
    let header = BASE64URL.encode(r#"{"alg":"HS256","typ":"JWT"}"#);
    let exp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
        + 300;
    let claims =
        json!({ "iss": API_KEY, "exp": exp, "sha256": BASE64STD.encode(Sha256::digest(&bytes)) });
    let signing_input = format!(
        "{header}.{}",
        BASE64URL.encode(serde_json::to_vec(&claims).unwrap())
    );
    let mut mac = <Hmac<Sha256>>::new_from_slice(API_SECRET.as_bytes()).unwrap();
    mac.update(signing_input.as_bytes());
    let token = format!(
        "{signing_input}.{}",
        BASE64URL.encode(mac.finalize().into_bytes())
    );
    Request::builder()
        .method("POST")
        .uri("/voice/webhook")
        .header("authorization", token)
        .header("content-type", "application/webhook+json")
        .body(Body::from(bytes))
        .unwrap()
}

struct World {
    app: Router,
    store: Store,
    voice: VoiceService,
    hub: Hub,
    present: Present,
    admin: String,
    alice: (String, String),
    bob: (String, String),
    lobby: String,
    _guard: support::TestDbGuard,
}

/// A LiveKit room service whose participant list is whatever `present` holds.
async fn fake_livekit(present: Present) -> String {
    async fn list(State(present): State<Present>) -> Json<Value> {
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
    let router = Router::new()
        .route("/twirp/livekit.RoomService/ListParticipants", post(list))
        .route("/twirp/livekit.RoomService/DeleteRoom", post(delete))
        .with_state(present);
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

async fn world(prefix: &str) -> World {
    let (path, guard) = support::TestDbGuard::new(prefix);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    let present: Present = Arc::default();
    let voice = VoiceService::for_test(&fake_livekit(present.clone()).await, API_KEY, API_SECRET);
    let hub = Hub::new();
    let app = http::router(AppState {
        store: store.clone(),
        auth: Auth::new(2).unwrap(),
        hub: hub.clone(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: voice.clone(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    });
    let (admin, _) = session(&store, "owner").await;
    let alice = session(&store, "alice").await;
    let bob = session(&store, "bob").await;
    let mut w = World {
        app,
        store,
        voice,
        hub,
        present,
        admin,
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
    async fn call(&self, method: &str, uri: &str, token: &str, body: Value) -> (StatusCode, Value) {
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

    async fn open_room(&self, token: &str) -> Value {
        let uri = format!("/channels/{}/voice/room", self.lobby);
        let (status, room) = self.call("POST", &uri, token, Value::Null).await;
        assert_eq!(status, StatusCode::OK, "{room}");
        room
    }

    async fn token_status(&self, token: &str, channel: &str) -> StatusCode {
        let uri = format!("/channels/{channel}/voice/token");
        self.call("POST", &uri, token, Value::Null).await.0
    }

    async fn listed(&self, token: &str, channel: &str) -> bool {
        let (_, list) = self.call("GET", "/channels", token, Value::Null).await;
        list.as_array()
            .unwrap()
            .iter()
            .any(|c| c["id"] == json!(channel))
    }

    async fn remove_if_empty(&self, channel: &str) {
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
    assert_eq!(room["room_locked"], false);
    assert_eq!(
        w.open_room(&w.alice.0).await["id"],
        room["id"],
        "one room each"
    );

    let other = w.open_room(&w.bob.0).await;
    assert_ne!(other["id"], room["id"]);
    assert!(w.listed(&w.bob.0, room["id"].as_str().unwrap()).await);

    let (_, lobby) = w.call("GET", "/channels", &w.alice.0, Value::Null).await;
    let lobby_row = lobby
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == json!(w.lobby))
        .unwrap()
        .clone();
    assert!(
        lobby_row.get("room_owner_id").is_none(),
        "a lobby is not a room"
    );
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
async fn an_empty_room_is_removed_and_a_busy_one_or_a_plain_channel_is_not() {
    let w = world("slimm-rooms-cleanup").await;
    let room = w.open_room(&w.alice.0).await;
    let id = room["id"].as_str().unwrap().to_owned();

    w.present.lock().unwrap().push(w.bob.1.clone());
    w.remove_if_empty(&id).await;
    assert!(w.listed(&w.alice.0, &id).await, "someone is still in it");

    w.present.lock().unwrap().clear();
    w.remove_if_empty(&w.lobby).await;
    assert!(
        w.listed(&w.alice.0, &w.lobby).await,
        "a lobby is never removed"
    );
    w.remove_if_empty(&id).await;
    assert!(!w.listed(&w.alice.0, &id).await, "the empty room is gone");

    let again = w.open_room(&w.alice.0).await;
    assert_ne!(
        again["id"],
        json!(id),
        "a fresh room after the old one went"
    );
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
async fn the_last_person_leaving_removes_the_room_through_the_webhook() {
    let w = world("slimm-rooms-webhook").await;
    let room = w.open_room(&w.alice.0).await;
    let id = room["id"].as_str().unwrap().to_owned();
    let left = json!({
        "event": "participant_left",
        "room": { "name": format!("channel-{id}") },
        "participant": { "identity": w.alice.1 },
    });
    let status = w
        .app
        .clone()
        .oneshot(signed_webhook(&left))
        .await
        .unwrap()
        .status();
    assert_eq!(status, StatusCode::NO_CONTENT);
    for _ in 0..40 {
        if !w.listed(&w.alice.0, &id).await {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("the emptied room was still listed after the webhook");
}
