// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Polls: one vote per user per poll (a second vote replaces rather than
//! doubling), refusal once closed, the per-channel SEND_MESSAGES gate, the
//! fan-out event's privacy, rate limiting, and cleanup on delete.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::{MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

type WsClient =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-polls");
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

fn app(store: Store) -> Router {
    http::router(state_for(&store))
}

fn request(method: &str, uri: &str, token: Option<&str>, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A member with a session, built straight through the store rather than
/// `/auth/register`, exactly like the reaction and pin tests: joining a
/// claimed deployment is an invite-gated policy decision covered elsewhere,
/// and these tests only need somebody signed in.
async fn register(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

async fn create_poll(
    app: &Router,
    channel_id: &str,
    token: &str,
    question: &str,
    options: &[&str],
    close_at: Option<i64>,
) -> Value {
    let mut body = json!({
        "id": Uuid::now_v7().to_string(),
        "question": question,
        "options": options,
    });
    if let Some(close_at) = close_at {
        body["close_at"] = json!(close_at);
    }
    json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel_id}/messages/polls"),
                Some(token),
                Some(body),
            ))
            .await
            .unwrap(),
    )
    .await
}

async fn vote(app: &Router, message_id: &str, token: &str, option: i64) -> StatusCode {
    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/messages/{message_id}/polls/vote"),
            Some(token),
            Some(json!({ "option": option })),
        ))
        .await
        .unwrap()
        .status()
}

/// A second vote by the same user must replace the first, not add to it: the
/// total must never double, and the tally must move entirely off the option
/// that was abandoned.
#[tokio::test]
async fn voting_twice_replaces_rather_than_doubles() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let poll = create_poll(
        &app,
        &channel.id.to_string(),
        &token,
        "tabs or spaces?",
        &["tabs", "spaces"],
        None,
    )
    .await;
    let message_id = poll["id"].as_str().unwrap().to_owned();

    assert_eq!(
        vote(&app, &message_id, &token, 0).await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        vote(&app, &message_id, &token, 1).await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        vote(&app, &message_id, &token, 1).await,
        StatusCode::NO_CONTENT
    );

    let listed = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{}/messages", channel.id),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let entry = &listed.as_array().unwrap()[0];
    let poll = &entry["poll"];
    assert_eq!(
        poll["total_votes"], 1,
        "three votes by one user must count once, not three times"
    );
    assert_eq!(
        poll["voted_option"], 1,
        "the latest vote must be the one that stands"
    );
    assert_eq!(
        poll["options"][0]["votes"], 0,
        "the abandoned option must lose the vote"
    );
    assert_eq!(poll["options"][1]["votes"], 1);
}

/// A vote after `close_at` has passed must be refused by the server, not
/// merely hidden by the client: the check is against the server's own clock.
#[tokio::test]
async fn vote_after_close_is_refused() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, user) = register(&store, "alice").await;

    // Through the store: the route refuses a close_at already past, see below.
    let message_id = MessageId(Uuid::now_v7());
    let options = ["yes".to_owned(), "no".to_owned()];
    store
        .send_poll_message(
            channel.id,
            UserId(user.parse().unwrap()),
            message_id,
            "",
            slimm_server::store::NewPoll {
                question: "already closed?",
                options: &options,
                close_at: Some(now_ms() - 1_000),
            },
        )
        .await
        .unwrap();
    let message_id = message_id.to_string();

    let status = vote(&app, &message_id, &token, 0).await;
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "a vote after close_at must be refused"
    );
}

/// A closing time must be ahead of now and at most 31 days out, so a typo
/// cannot make a poll closed on arrival or pin one open for years.
#[tokio::test]
async fn close_at_must_be_soon_and_in_the_future() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;
    let day = 24 * 60 * 60 * 1000;

    for (close_at, expected) in [
        (now_ms() - 1_000, StatusCode::BAD_REQUEST),
        (now_ms() + 32 * day, StatusCode::BAD_REQUEST),
        (now_ms() + day, StatusCode::OK),
    ] {
        let body = json!({
            "id": Uuid::now_v7().to_string(),
            "question": "lunch?",
            "options": ["yes", "no"],
            "close_at": close_at,
        });
        let response = app
            .clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{}/messages/polls", channel.id),
                Some(&token),
                Some(body),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), expected, "close_at {close_at}");
    }
}

/// Voting requires the same permission sending a message does, evaluated per
/// channel: holding it via `@everyone` in one channel must not let a caller
/// vote in a different channel where a per-member overwrite strips it back
/// off, the same distinction that mattered for pinning elsewhere in this
/// project (see CLAUDE.md).
#[tokio::test]
async fn voting_needs_send_permission_evaluated_per_channel() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());

    let (creator_token, _creator_id) = register(&store, "creator").await;
    let (voter_token, voter_id) = register(&store, "voter").await;
    let voter = UserId(Uuid::parse_str(&voter_id).unwrap());

    let channel_a = store.create_channel("channel-a", "text").await.unwrap();
    let channel_b = store.create_channel("channel-b", "text").await.unwrap();
    // Strip SEND_MESSAGES from the voter, but only in channel_b.
    store
        .set_member_overwrite(
            channel_b.id,
            voter,
            Permissions::NONE,
            Permissions::SEND_MESSAGES,
        )
        .await
        .unwrap();

    let poll_a = create_poll(
        &app,
        &channel_a.id.to_string(),
        &creator_token,
        "a?",
        &["x", "y"],
        None,
    )
    .await;
    let poll_b = create_poll(
        &app,
        &channel_b.id.to_string(),
        &creator_token,
        "b?",
        &["x", "y"],
        None,
    )
    .await;

    let denied = vote(&app, poll_b["id"].as_str().unwrap(), &voter_token, 0).await;
    assert_eq!(
        denied,
        StatusCode::FORBIDDEN,
        "the per-channel overwrite must win over the role grant"
    );

    let allowed = vote(&app, poll_a["id"].as_str().unwrap(), &voter_token, 0).await;
    assert_eq!(
        allowed,
        StatusCode::NO_CONTENT,
        "the same role must still grant it in a channel with no overwrite"
    );
}

/// Deleting the message must remove the poll: it becomes unreadable at the
/// store level the same instant the message is soft-deleted, driven by the
/// same trigger-on-`deleted_at` mechanism pinned messages already rely on.
#[tokio::test]
async fn deleting_the_message_removes_the_poll() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let poll = create_poll(
        &app,
        &channel.id.to_string(),
        &token,
        "gone soon?",
        &["yes", "no"],
        None,
    )
    .await;
    let message_id_str = poll["id"].as_str().unwrap().to_owned();
    let message_id = MessageId(Uuid::parse_str(&message_id_str).unwrap());

    assert_eq!(
        vote(&app, &message_id_str, &token, 0).await,
        StatusCode::NO_CONTENT
    );
    assert!(
        store
            .poll_for_message(message_id, UserId::generate())
            .await
            .unwrap()
            .is_some(),
        "sanity check: the poll and its vote exist before deletion"
    );

    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}/messages/{message_id_str}", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    assert!(
        store
            .poll_for_message(message_id, UserId::generate())
            .await
            .unwrap()
            .is_none(),
        "the poll (and by the same cascade, its votes) must not survive its message's deletion"
    );
}

/// Every other mutating route in this codebase charges a rate limit; voting
/// must too.
#[tokio::test]
async fn voting_is_rate_limited() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let poll = create_poll(
        &app,
        &channel.id.to_string(),
        &token,
        "rate limit me",
        &["a", "b"],
        None,
    )
    .await;
    let message_id = poll["id"].as_str().unwrap().to_owned();

    let mut statuses = Vec::new();
    for i in 0..60 {
        statuses.push(vote(&app, &message_id, &token, i % 2).await);
    }

    assert!(
        statuses.contains(&StatusCode::NO_CONTENT),
        "the first votes inside the burst are answered: {statuses:?}"
    );
    assert!(
        statuses.contains(&StatusCode::TOO_MANY_REQUESTS),
        "a sustained vote flood must be refused: {statuses:?}"
    );
}

/// Poll creation is a message send and must be rate limited the same way.
#[tokio::test]
async fn poll_creation_is_rate_limited() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let mut statuses = Vec::new();
    for _ in 0..60 {
        let body = json!({
            "id": Uuid::now_v7().to_string(),
            "question": "rate limit me",
            "options": ["a", "b"],
        });
        let response = app
            .clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{}/messages/polls", channel.id),
                Some(&token),
                Some(body),
            ))
            .await
            .unwrap();
        statuses.push(response.status());
    }

    assert!(
        statuses.contains(&StatusCode::OK),
        "the first creates inside the burst are answered: {statuses:?}"
    );
    assert!(
        statuses.contains(&StatusCode::TOO_MANY_REQUESTS),
        "a sustained create flood must be refused: {statuses:?}"
    );
}

// --- Fan-out privacy, over a real WebSocket ---

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

async fn connect(addr: std::net::SocketAddr, ticket: &str) -> WsClient {
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

async fn read_frame(ws: &mut WsClient) -> Value {
    loop {
        match ws.next().await {
            Some(Ok(WsMessage::Text(text))) => return serde_json::from_str(text.as_str()).unwrap(),
            Some(Ok(_)) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

/// Reads frames until one with the given `type`, skipping anything else (this
/// connection's own presence-changed frame among them). Bounded so a genuine
/// regression fails the test instead of hanging it.
async fn read_frame_of_type(ws: &mut WsClient, frame_type: &str) -> Value {
    for _ in 0..10 {
        let frame = read_frame(ws).await;
        if frame["type"] == frame_type {
            return frame;
        }
    }
    panic!("did not see a `{frame_type}` frame within 10 frames");
}

/// The `poll.voted` fan-out event must carry only channel, message, and each
/// option's public tally, exactly mirroring `ReactionsChanged`'s own
/// deliberate omission of the per-viewer flag: nothing here may ever say
/// which user cast which vote.
#[tokio::test]
async fn poll_vote_event_never_reveals_the_voter() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = state_for(&store);

    let (alice_access, alice_ticket) = user_ticket(&store, "alice").await;
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;

    let router = http::router(state.clone());
    let poll = create_poll(
        &router,
        &channel.id.to_string(),
        &alice_access,
        "q?",
        &["a", "b"],
        None,
    )
    .await;
    // Drain to the poll's own message.created; a presence-changed frame may land in between.
    read_frame_of_type(&mut alice_ws, "message.created").await;

    let message_id = poll["id"].as_str().unwrap().to_owned();
    let status = vote(&router, &message_id, &alice_access, 0).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let frame = read_frame_of_type(&mut alice_ws, "poll.voted").await;
    assert_eq!(frame["options"][0]["votes"], 1);
    assert_eq!(frame["options"][1]["votes"], 0);

    let top_level_keys: std::collections::BTreeSet<String> =
        frame.as_object().unwrap().keys().cloned().collect();
    let expected: std::collections::BTreeSet<String> =
        ["type", "channel_id", "message_id", "options"]
            .iter()
            .map(|s| s.to_string())
            .collect();
    assert_eq!(
        top_level_keys, expected,
        "the event must carry only channel, message and per-option counts, never who voted"
    );
    for option in frame["options"].as_array().unwrap() {
        let keys: std::collections::BTreeSet<String> =
            option.as_object().unwrap().keys().cloned().collect();
        let expected_option: std::collections::BTreeSet<String> = ["position", "votes"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(
            keys, expected_option,
            "each option must carry only its position and count, never a voter identity"
        );
    }
}
