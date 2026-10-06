// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Regression coverage for `message.created`'s own enrichment: a second
//! connected client must see the same app surface and poll a cold REST read
//! would show, not `null` until it resyncs. Before this file, an app or a
//! poll sent while someone else was watching the channel arrived blank on
//! their live frame and only appeared once they reopened it.
//!
//! See `crates/slimm-server/src/http/ws/message_frames.rs` and
//! `crates/slimm-server/src/hub/event.rs::Event::MessageCreated`.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
    Store, User,
};
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;
use uuid::Uuid;

mod support;
use support::wasm_fixtures::{canned_ok_wasm, sha256_hex};

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn state_for(store: &Store) -> AppState {
    AppState {
        store: store.clone(),
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    }
}

/// Creates a user and returns (rest access token, ws connect ticket).
async fn user_ticket(store: &Store, name: &str) -> (String, String) {
    let user = store.create_user(name, name).await.unwrap();
    let tokens = store.open_session(user.id, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    (tokens.access_token, ticket)
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
    let ack = read_frame(&mut ws).await;
    assert_eq!(ack["type"], "hello");
    ws
}

/// Reads the next text frame as JSON, skipping `presence.changed` - real,
/// expected chatter from connecting these sockets, not what any test here
/// checks. See `tests/ws.rs::read_frame`, which this mirrors.
async fn read_frame(ws: &mut Client) -> Value {
    loop {
        match ws.next().await {
            Some(Ok(WsMessage::Text(text))) => {
                let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                if frame["type"] == "presence.changed" {
                    continue;
                }
                return frame;
            }
            Some(Ok(_)) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

fn post(uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

/// Installs `widget` with an `app` extension point that launches its `surf`
/// command, gated on the `play` permission - just enough to launch one,
/// mirroring `tests/apps.rs`'s own fixture.
async fn install_launchable_app(s: &Store) {
    let wasm = canned_ok_wasm("done");
    let sha256 = sha256_hex(&wasm);
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: "widget",
            name: "Widget",
            version: "0.1.0",
            artifact_sha256: &sha256,
            approved_capabilities: &[],
            runtime_limits: &ModuleRuntimeLimits::default(),
            permissions: &[ModulePermissionSpec {
                key: "play",
                name: "Play the widget",
                description: "launch and play it",
            }],
            extension_points: &[ModuleExtensionPointSpec {
                kind: "app",
                name: "Widget",
                description: Some("Launch the widget in chat"),
                permission: Some("play"),
                command: Some("surf"),
                language: None,
            }],
        },
        &wasm,
    )
    .await
    .unwrap();
    s.set_module_enabled("widget", true).await.unwrap();
}

/// Grants `widget:play` to a fresh role and assigns it to `user`.
async fn grant_play(s: &Store, user: &User) {
    let role = s
        .create_role("players", Permissions::NONE, false)
        .await
        .unwrap();
    s.assign_role(user.id, role).await.unwrap();
    s.grant_module_permission(role, "widget", "play")
        .await
        .unwrap();
}

/// The bug in the owner's own words: launching a game into the chat showed
/// the board correctly for the sender, but a second connected client's live
/// frame carried no `app_surface` at all and rendered a blank message until
/// they reopened the channel.
#[tokio::test]
async fn a_second_client_sees_the_launched_app_live() {
    let (store, _guard) = new_store("slimm-ws-app-live").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    install_launchable_app(&store).await;

    let author = store.create_user("nia", "Nia").await.unwrap();
    grant_play(&store, &author).await;
    let author_tokens = store.open_session(author.id, "phone").await.unwrap();

    let (_watcher_access, watcher_ticket) = user_ticket(&store, "watcher").await;

    let state = state_for(&store);
    let addr = serve(state.clone()).await;
    let mut watcher_ws = connect(addr, &watcher_ticket).await;

    let uri = format!("/channels/{}/messages/apps", channel.id);
    let response = http::router(state.clone())
        .oneshot(post(
            &uri,
            &author_tokens.access_token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "",
                "module_id": "widget",
                "command": "surf",
            }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let frame = read_frame(&mut watcher_ws).await;
    assert_eq!(frame["type"], "message.created");
    assert_eq!(frame["message"]["app_surface"]["module_id"], "widget");
    assert_eq!(frame["message"]["app_surface"]["command"], "surf");
}

/// The same defect, for a poll: `attach_polls` fills a cold read in but the
/// live path never called it, so a poll sent while someone was watching
/// arrived with `poll: null` too.
#[tokio::test]
async fn a_second_client_sees_a_poll_live() {
    let (store, _guard) = new_store("slimm-ws-poll-live").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();

    let author = store.create_user("nia", "Nia").await.unwrap();
    let author_tokens = store.open_session(author.id, "phone").await.unwrap();

    let (_watcher_access, watcher_ticket) = user_ticket(&store, "watcher").await;

    let state = state_for(&store);
    let addr = serve(state.clone()).await;
    let mut watcher_ws = connect(addr, &watcher_ticket).await;

    let uri = format!("/channels/{}/messages/polls", channel.id);
    let response = http::router(state.clone())
        .oneshot(post(
            &uri,
            &author_tokens.access_token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "question": "cats or dogs",
                "options": ["cats", "dogs"],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let frame = read_frame(&mut watcher_ws).await;
    assert_eq!(frame["type"], "message.created");
    assert_eq!(frame["message"]["poll"]["question"], "cats or dogs");
    assert_eq!(
        frame["message"]["poll"]["voted_option"],
        Value::Null,
        "nobody can have voted before the frame announcing the poll's creation"
    );
    assert_eq!(frame["message"]["poll"]["options"][0]["label"], "cats");
}

/// The common case must keep working, and must not gain the lookups the two
/// tests above exercise: an ordinary message launches no app and carries no
/// poll, so both fields stay `null` and `code_runs` stays empty.
#[tokio::test]
async fn an_ordinary_message_carries_no_app_or_poll_live() {
    let (store, _guard) = new_store("slimm-ws-plain-live").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();

    let (author_access, _author_ticket) = user_ticket(&store, "alice").await;
    let (_watcher_access, watcher_ticket) = user_ticket(&store, "watcher").await;

    let state = state_for(&store);
    let addr = serve(state.clone()).await;
    let mut watcher_ws = connect(addr, &watcher_ticket).await;

    let uri = format!("/channels/{}/messages", channel.id);
    let response = http::router(state.clone())
        .oneshot(post(
            &uri,
            &author_access,
            json!({ "id": Uuid::now_v7().to_string(), "content": "hello" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let frame = read_frame(&mut watcher_ws).await;
    assert_eq!(frame["type"], "message.created");
    assert_eq!(frame["message"]["app_surface"], Value::Null);
    assert_eq!(frame["message"]["poll"], Value::Null);
    assert_eq!(frame["message"]["code_runs"], json!([]));
}

/// A brand new message can already carry an attachment, and the live frame is
/// the only thing a connected client sees until its next sync.
///
/// The frame used to be built from a bare row, which cannot express one, so an
/// image arrived as an empty message and only gained its picture on reconnect.
#[tokio::test]
async fn a_live_frame_carries_the_attachment_the_message_was_sent_with() {
    let (store, _guard) = new_store("ws_live_attachment").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = state_for(&store);

    let (alice_access, _alice_ticket) = user_ticket(&store, "alice").await;
    let alice_id = store
        .authenticate(&alice_access)
        .await
        .unwrap()
        .unwrap()
        .user_id;
    let (_bob_access, bob_ticket) = user_ticket(&store, "bob").await;

    // Stored directly, since the fan-out is under test; the id is a sha256 and a short one is refused.
    let bytes = [0x11u8; 32];
    store
        .store_attachment(
            &bytes,
            bytes.len() as i64,
            "image/png",
            "shot.png",
            Some(alice_id),
        )
        .await
        .unwrap();
    let attachment_id: String = bytes.iter().map(|b| format!("{b:02x}")).collect();

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let uri = format!("/channels/{}/messages", channel.id);
    let response = http::router(state.clone())
        .oneshot(post(
            &uri,
            &alice_access,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "look at this",
                "attachment_ids": [attachment_id],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let frame = read_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "message.created");
    let attachments = frame["message"]["attachments"]
        .as_array()
        .expect("the frame carries an attachments array");
    assert_eq!(
        attachments.len(),
        1,
        "the live frame must carry the attachment, not leave it for the next sync: {frame}"
    );
    assert_eq!(attachments[0]["filename"], "shot.png");
    assert_eq!(attachments[0]["content_type"], "image/png");
}
