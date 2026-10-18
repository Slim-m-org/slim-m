// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live coverage for the LiveKit-webhook-sourced screen-share event:
//! `Event::VoiceScreenShareChanged`. See
//! `docs/decisions/0032-voice-participant-webhooks.md`.
//!
//! Join/leave coverage, and the signature-verification tests both files
//! would otherwise duplicate, is `live_voice_participant_events.rs`; split
//! out here to stay under the file-size budget.

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

/// `member()` mints a session but not a ws ticket for the account it just
/// bootstrapped; this bridges the two.
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

fn track_published(room: &str, identity: &str, sid: &str, source: &str) -> Value {
    json!({
        "event": "track_published",
        "room": { "name": room },
        "participant": { "identity": identity },
        "track": { "sid": sid, "source": source },
    })
}

fn track_unpublished(room: &str, identity: &str, sid: &str, source: &str) -> Value {
    json!({
        "event": "track_unpublished",
        "room": { "name": room },
        "participant": { "identity": identity },
        "track": { "sid": sid, "source": source },
    })
}

/// Sets up a voice channel, a joined alice and a connected bob watching it -
/// the common setup every test in this file starts from.
async fn joined_channel_and_viewer() -> (
    Store,
    support::TestDbGuard,
    AppState,
    String,
    String,
    Client,
) {
    let (store, guard) = support::new_store("slimm-live-voice-screen-share-events-test").await;
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
    deliver(http::router(state.clone()), joined(&room, &alice_id)).await;
    read_frame_of_type(&mut bob_ws, "voice.participant_joined").await;

    (store, guard, state, room, alice_id, bob_ws)
}

#[tokio::test]
async fn a_screen_share_start_and_stop_are_delivered() {
    let (_store, _guard, state, room, alice_id, mut bob_ws) = joined_channel_and_viewer().await;

    let status = deliver(
        http::router(state.clone()),
        track_published(&room, &alice_id, "TR_video", "SCREEN_SHARE"),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let frame = read_frame_of_type(&mut bob_ws, "voice.screen_share_changed").await;
    assert_eq!(frame["user_id"], alice_id);
    assert_eq!(frame["is_sharing_screen"], true);

    // A second, accompanying audio track must not re-report a fresh start.
    deliver(
        http::router(state.clone()),
        track_published(&room, &alice_id, "TR_audio", "SCREEN_SHARE_AUDIO"),
    )
    .await;
    assert!(
        wait_for(
            &mut bob_ws,
            "voice.screen_share_changed",
            Duration::from_millis(300)
        )
        .await
        .is_none(),
        "a second screen-share track is not a fresh start"
    );

    // Unpublishing video alone must not report sharing stopped while audio is still up.
    deliver(
        http::router(state.clone()),
        track_unpublished(&room, &alice_id, "TR_video", "SCREEN_SHARE"),
    )
    .await;
    assert!(
        wait_for(
            &mut bob_ws,
            "voice.screen_share_changed",
            Duration::from_millis(300)
        )
        .await
        .is_none(),
        "the audio track is still up"
    );

    let status = deliver(
        http::router(state.clone()),
        track_unpublished(&room, &alice_id, "TR_audio", "SCREEN_SHARE_AUDIO"),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let frame = read_frame_of_type(&mut bob_ws, "voice.screen_share_changed").await;
    assert_eq!(frame["is_sharing_screen"], false);
}

/// A track publish that is not screen-share sourced (an ordinary camera or
/// microphone) must never surface as a screen-share change.
#[tokio::test]
async fn a_non_screen_share_track_publishes_nothing() {
    let (_store, _guard, state, room, alice_id, mut bob_ws) = joined_channel_and_viewer().await;

    let status = deliver(
        http::router(state.clone()),
        track_published(&room, &alice_id, "TR_cam", "CAMERA"),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(
        wait_for(
            &mut bob_ws,
            "voice.screen_share_changed",
            Duration::from_millis(300)
        )
        .await
        .is_none()
    );
}

/// A redelivered `track_unpublished` for a track already gone is not a
/// second stop (issue 2085).
#[tokio::test]
async fn a_duplicate_unpublish_does_not_republish_a_stop() {
    let (_store, _guard, state, room, alice_id, mut bob_ws) = joined_channel_and_viewer().await;
    let app = http::router(state.clone());
    deliver(
        app.clone(),
        track_published(&room, &alice_id, "TR_video", "SCREEN_SHARE"),
    )
    .await;
    read_frame_of_type(&mut bob_ws, "voice.screen_share_changed").await;
    let stop = track_unpublished(&room, &alice_id, "TR_video", "SCREEN_SHARE");
    deliver(app.clone(), stop.clone()).await;
    read_frame_of_type(&mut bob_ws, "voice.screen_share_changed").await;

    deliver(app, stop).await;
    assert!(
        wait_for(
            &mut bob_ws,
            "voice.screen_share_changed",
            Duration::from_millis(300)
        )
        .await
        .is_none(),
        "the duplicate stop was published again"
    );
}

fn with_participant_sid(mut event: Value, sid: &str) -> Value {
    event["participant"]["sid"] = json!(sid);
    event
}

/// A track webhook from a session that already left must not leave behind an
/// entry that swallows the member's next real join (issue 2086).
#[tokio::test]
async fn a_late_track_after_leaving_does_not_swallow_the_rejoin() {
    let (_store, _guard, state, room, alice_id, mut bob_ws) = joined_channel_and_viewer().await;
    let app = http::router(state.clone());
    let left = json!({
        "event": "participant_left",
        "room": { "name": room },
        "participant": { "identity": alice_id },
    });
    deliver(app.clone(), left).await;
    read_frame_of_type(&mut bob_ws, "voice.participant_left").await;
    let late = track_published(&room, &alice_id, "TR_old", "SCREEN_SHARE");
    deliver(app.clone(), late).await;

    deliver(
        app,
        with_participant_sid(joined(&room, &alice_id), "PA_second"),
    )
    .await;
    assert!(
        wait_for(
            &mut bob_ws,
            "voice.participant_joined",
            Duration::from_secs(2)
        )
        .await
        .is_some(),
        "the rejoin was swallowed by the stale entry"
    );
}
