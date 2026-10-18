// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live coverage for the LiveKit-webhook-sourced join/leave events:
//! `Event::VoiceParticipantJoined` and `VoiceParticipantLeft`. See
//! `docs/decisions/0032-voice-participant-webhooks.md`.
//!
//! Screen-share coverage is `live_voice_screen_share_events.rs`, split out
//! to stay under the file-size budget.
//!
//! Each test drives `POST /voice/webhook` with a delivery signed the same
//! way LiveKit's own server SDKs sign one, through the crate's real
//! verification path - not a mock of it - and asserts what reaches a raw
//! websocket subscriber.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64STD;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use slimm_server::http::{self, AppState};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

const API_KEY: &str = "APItestkey";
const API_SECRET: &str = "a-test-secret-of-at-least-32-characters";

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

fn enabled_voice() -> VoiceService {
    VoiceService::for_test("wss://livekit.example.com", API_KEY, API_SECRET)
}

fn state_for(store: &Store) -> AppState {
    support::app::builder(store.clone())
        .voice(enabled_voice())
        .build()
}

async fn member(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let access = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (access, account.id.to_string())
}

async fn user_ticket(store: &Store, name: &str) -> String {
    let user = store.create_user(name, name).await.unwrap();
    let tokens = store.open_session(user.id, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    ticket
}

/// `member()` mints a session but not a ws ticket for the account it just
/// bootstrapped; this bridges the two for a test that needs a live socket
/// for a `member()`-created account rather than a fresh `create_user`.
async fn user_ticket_from_access(store: &Store, access_token: &str) -> String {
    let ctx = store.authenticate(access_token).await.unwrap().unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    ticket
}

async fn serve(state: AppState) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, http::router(state)).await.unwrap();
    });
    addr
}

async fn connect(addr: std::net::SocketAddr, ticket: &str) -> Client {
    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();
    let ack = wait_for(&mut ws, "hello", Duration::from_secs(2))
        .await
        .expect("hello ack");
    assert_eq!(ack["type"], "hello");
    ws
}

async fn wait_for(ws: &mut Client, kind: &str, timeout: Duration) -> Option<Value> {
    tokio::time::timeout(timeout, async {
        loop {
            match ws.next().await {
                Some(Ok(WsMessage::Text(text))) => {
                    let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                    if frame["type"] == kind {
                        return frame;
                    }
                }
                Some(Ok(_)) => continue,
                other => panic!("expected a text frame, got {other:?}"),
            }
        }
    })
    .await
    .ok()
}

async fn read_frame_of_type(ws: &mut Client, kind: &str) -> Value {
    wait_for(ws, kind, Duration::from_secs(2))
        .await
        .unwrap_or_else(|| panic!("timed out waiting for a `{kind}` frame"))
}

/// Signs a webhook body exactly the way LiveKit's own server SDKs do:
/// HS256 over `header.payload`, with a base64-standard sha256 digest of the
/// body as a claim rather than the body itself.
fn sign_webhook(body: &[u8], api_key: &str, api_secret: &str) -> String {
    let header = BASE64URL.encode(r#"{"alg":"HS256","typ":"JWT"}"#);
    let sha256 = BASE64STD.encode(Sha256::digest(body));
    let exp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
        + 300;
    let claims = json!({ "iss": api_key, "exp": exp, "sha256": sha256 });
    let payload = BASE64URL.encode(serde_json::to_vec(&claims).unwrap());
    let signing_input = format!("{header}.{payload}");
    let mut mac = <Hmac<Sha256>>::new_from_slice(api_secret.as_bytes()).unwrap();
    mac.update(signing_input.as_bytes());
    let signature = BASE64URL.encode(mac.finalize().into_bytes());
    format!("{signing_input}.{signature}")
}

fn webhook_request(body: Value, api_key: &str, api_secret: &str) -> Request<Body> {
    let bytes = serde_json::to_vec(&body).unwrap();
    let token = sign_webhook(&bytes, api_key, api_secret);
    Request::builder()
        .method("POST")
        .uri("/voice/webhook")
        .header("authorization", token)
        .header("content-type", "application/webhook+json")
        .body(Body::from(bytes))
        .unwrap()
}

async fn deliver(app: axum::Router, body: Value) -> StatusCode {
    app.oneshot(webhook_request(body, API_KEY, API_SECRET))
        .await
        .unwrap()
        .status()
}

fn joined(room: &str, identity: &str) -> Value {
    json!({
        "event": "participant_joined",
        "room": { "name": room },
        "participant": { "identity": identity },
    })
}

fn left(room: &str, identity: &str) -> Value {
    json!({
        "event": "participant_left",
        "room": { "name": room },
        "participant": { "identity": identity },
    })
}

/// A signature LiveKit's own server SDKs would never produce must be
/// refused, not merely ignored - the "prove the gate can fail" half of this
/// file's own coverage.
#[tokio::test]
async fn a_delivery_with_a_bad_signature_is_refused() {
    let (store, _guard) = support::new_store("slimm-live-voice-participant-events-test").await;
    let app = http::router(state_for(&store));
    let body = joined("channel-does-not-matter", "someone");
    let bytes = serde_json::to_vec(&body).unwrap();
    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/voice/webhook")
                .header("authorization", "not-a-real-jwt")
                .body(Body::from(bytes))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// A delivery signed with the wrong secret is refused the same way.
#[tokio::test]
async fn a_delivery_signed_with_the_wrong_secret_is_refused() {
    let (store, _guard) = support::new_store("slimm-live-voice-participant-events-test").await;
    let app = http::router(state_for(&store));
    let body = joined("channel-does-not-matter", "someone");
    let bytes = serde_json::to_vec(&body).unwrap();
    let token = sign_webhook(&bytes, API_KEY, "a-completely-different-secret-of-32-chars");
    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/voice/webhook")
                .header("authorization", token)
                .body(Body::from(bytes))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_join_reaches_a_channel_viewer_but_not_a_stranger() {
    // A DM, so VIEW_CHANNEL there is structurally limited to the two participants.
    let (store, _guard) = support::new_store("slimm-live-voice-participant-events-test").await;
    let alice = store.create_user("alice", "alice").await.unwrap();
    let bob = store.create_user("bob", "bob").await.unwrap();
    let channel = store.open_dm(alice.id, bob.id).await.unwrap();
    let alice_id = alice.id.to_string();
    let eve_ticket = user_ticket(&store, "eve").await;

    let state = state_for(&store);
    let addr = serve(state.clone()).await;
    let mut eve_ws = connect(addr, &eve_ticket).await;

    let room = slimm_server::voice::room_for_channel(channel.id);
    let status = deliver(http::router(state.clone()), joined(&room, &alice_id)).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    assert!(
        wait_for(
            &mut eve_ws,
            "voice.participant_joined",
            Duration::from_millis(300)
        )
        .await
        .is_none(),
        "eve cannot view this channel and must learn nothing"
    );
}

#[tokio::test]
async fn a_join_and_leave_are_delivered_with_the_participant_named() {
    let (store, _guard) = support::new_store("slimm-live-voice-participant-events-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "voice").await.unwrap();
    let (_alice_token, alice_id) = member(&store, "alice").await;
    let (bob_token, _bob_viewer_id) = member(&store, "bob-viewer").await;
    let bob_ticket = user_ticket_from_access(&store, &bob_token).await;

    let state = state_for(&store);
    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let room = slimm_server::voice::room_for_channel(channel.id);
    let status = deliver(http::router(state.clone()), joined(&room, &alice_id)).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let frame = read_frame_of_type(&mut bob_ws, "voice.participant_joined").await;
    assert_eq!(frame["channel_id"], channel.id.to_string());
    assert_eq!(frame["user_id"], alice_id);

    let status = deliver(http::router(state.clone()), left(&room, &alice_id)).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let frame = read_frame_of_type(&mut bob_ws, "voice.participant_left").await;
    assert_eq!(frame["user_id"], alice_id);
}

/// A retried delivery for the same transition (LiveKit does not promise
/// exactly-once) must not republish.
#[tokio::test]
async fn a_duplicate_join_webhook_does_not_republish() {
    let (store, _guard) = support::new_store("slimm-live-voice-participant-events-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "voice").await.unwrap();
    let (_alice_token, alice_id) = member(&store, "alice").await;
    let (bob_token, _bob_viewer_id) = member(&store, "bob-viewer").await;
    let bob_ticket = user_ticket_from_access(&store, &bob_token).await;

    let state = state_for(&store);
    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let room = slimm_server::voice::room_for_channel(channel.id);
    for _ in 0..3 {
        let status = deliver(http::router(state.clone()), joined(&room, &alice_id)).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    }

    read_frame_of_type(&mut bob_ws, "voice.participant_joined").await;
    assert!(
        wait_for(
            &mut bob_ws,
            "voice.participant_joined",
            Duration::from_millis(300)
        )
        .await
        .is_none(),
        "a retried participant_joined for the same pair must not republish"
    );
}

/// Appear-offline applies to the push path exactly as it does to
/// `GET .../voice/roster`: a hidden participant's join must reach nobody
/// but themselves.
#[tokio::test]
async fn a_hidden_participants_join_reaches_only_themselves() {
    let (store, _guard) = support::new_store("slimm-live-voice-participant-events-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "voice").await.unwrap();
    let (alice_token, alice_id) = member(&store, "alice").await;
    let (bob_token, _bob_id) = member(&store, "bob-viewer").await;
    let alice_ticket = user_ticket_from_access(&store, &alice_token).await;
    let bob_ticket = user_ticket_from_access(&store, &bob_token).await;

    let state = state_for(&store);
    let app = http::router(state.clone());
    let hide = app
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri("/presence")
                .header("authorization", format!("Bearer {alice_token}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({ "visibility": "hidden" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(hide.status(), StatusCode::OK);

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let room = slimm_server::voice::room_for_channel(channel.id);
    let status = deliver(http::router(state.clone()), joined(&room, &alice_id)).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    read_frame_of_type(&mut alice_ws, "voice.participant_joined").await;
    assert!(
        wait_for(
            &mut bob_ws,
            "voice.participant_joined",
            Duration::from_millis(300)
        )
        .await
        .is_none(),
        "a hidden participant's join must not reach another viewer"
    );
}
