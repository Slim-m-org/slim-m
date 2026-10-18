// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! End-to-end typing indicator tests: channel-view authorization (reusing the
//! same permission check messages and reactions already go through), the
//! self-expiring lapse with no explicit stop frame, and rate limiting.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use sqlx::SqlitePool;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod support;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Like [`new_store`], but also hands back the raw pool so a test can reach
/// past the `Store` seam and break a single query for real, rather than the
/// whole database (see `a_store_error_resolving_presence_withholds_typing`).
async fn new_store_with_pool() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-typing-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

async fn user_ticket(store: &Store, name: &str) -> (String, slimm_server::ids::UserId) {
    let user = store.create_user(name, name).await.unwrap();
    let tokens = store.open_session(user.id, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    (ticket, user.id)
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

async fn read_frame(ws: &mut Client) -> Value {
    loop {
        match ws.next().await {
            Some(Ok(WsMessage::Text(text))) => {
                return serde_json::from_str(text.as_str()).unwrap();
            }
            Some(Ok(_)) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

/// Reads frames until one is `frame_type` for `channel_id`, ignoring anything
/// else (including this connection's own presence-changed frames from
/// connecting). Bounded so a missing event fails the test instead of hanging.
async fn next_of_type(ws: &mut Client, frame_type: &str, channel_id: &str) -> Value {
    let outcome = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let frame = read_frame(ws).await;
            if frame["type"] == frame_type && frame["channel_id"] == channel_id {
                return frame;
            }
        }
    })
    .await;
    outcome.unwrap_or_else(|_| panic!("no {frame_type} for {channel_id} arrived in time"))
}

/// Asserts nothing of `frame_type` for `channel_id` arrives within a short
/// window, used both for the negative-authorization test and to confirm a
/// rate-limited refresh did not fan out.
async fn assert_nothing_of_type(ws: &mut Client, frame_type: &str, channel_id: &str) {
    let outcome = tokio::time::timeout(
        Duration::from_millis(300),
        next_of_type(ws, frame_type, channel_id),
    )
    .await;
    assert!(outcome.is_err(), "unexpected {frame_type} for {channel_id}");
}

async fn send_typing(ws: &mut Client, channel_id: &str) {
    ws.send(WsMessage::Text(
        json!({ "type": "typing", "channel_id": channel_id }).to_string(),
    ))
    .await
    .unwrap();
}

/// A typing signal reaches a user who can view the channel.
#[tokio::test]
async fn typing_reaches_a_viewer() {
    let (store, _guard) = support::new_store("slimm-typing-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();

    let (alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (bob_ticket, _bob_id) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_typing(&mut alice_ws, &channel.id.to_string()).await;

    let frame = next_of_type(&mut bob_ws, "typing.started", &channel.id.to_string()).await;
    assert_eq!(frame["user_id"], alice_id.to_string());
}

/// A typing signal does NOT reach a user who cannot view the channel, reusing
/// the same per-event authorization messages and reactions go through.
#[tokio::test]
async fn typing_does_not_reach_a_non_viewer() {
    let (store, _guard) = support::new_store("slimm-typing-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();

    let (alice_ticket, _alice_id) = user_ticket(&store, "alice").await;
    let (bob_ticket, bob_id) = user_ticket(&store, "bob").await;

    // Deny bob the view of this channel specifically, the same setup
    // `fan_out_respects_view_permission` in tests/ws.rs uses for messages.
    store
        .set_member_overwrite(
            channel.id,
            bob_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_typing(&mut alice_ws, &channel.id.to_string()).await;

    assert_nothing_of_type(&mut bob_ws, "typing.started", &channel.id.to_string()).await;
}

/// A typing state lapses on its own a few seconds after the last refresh,
/// with no explicit "stop typing" frame from the client: the server itself
/// publishes `typing.stopped` once its TTL elapses.
#[tokio::test]
async fn typing_lapses_without_a_refresh() {
    let (store, _guard) = support::new_store("slimm-typing-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    // A short TTL so the test does not wait out the production few seconds.
    let state = support::app::builder(store.clone())
        .hub(Hub::with_typing_ttl(Duration::from_millis(150)))
        .build();

    let (alice_ticket, _alice_id) = user_ticket(&store, "alice").await;
    let (bob_ticket, _bob_id) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_typing(&mut alice_ws, &channel.id.to_string()).await;
    next_of_type(&mut bob_ws, "typing.started", &channel.id.to_string()).await;

    // Alice sends nothing further. Bob should still see it lapse on its own.
    let stopped = tokio::time::timeout(
        Duration::from_secs(2),
        next_of_type(&mut bob_ws, "typing.stopped", &channel.id.to_string()),
    )
    .await;
    assert!(
        stopped.is_ok(),
        "a typing state must lapse on its own without a refresh"
    );
}

/// A refresh sent well within the TTL keeps the state alive rather than
/// letting it lapse, and does not re-fan-out a second `typing.started`.
///
/// Waiting up to t=650ms is comfortably past the original (now-superseded)
/// t=400ms deadline while staying clear of the refreshed one, so nothing
/// arriving proves both halves at once: no rebroadcast of "started", and no
/// "stopped" let through by the old deadline either.
#[tokio::test]
async fn a_refresh_within_the_ttl_does_not_lapse_or_repeat() {
    let (store, _guard) = support::new_store("slimm-typing-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    // A refresh well before this deadline should push it out rather than
    // merely being ignored; see the timing note below.
    let ttl = Duration::from_millis(400);
    let state = support::app::builder(store.clone())
        .hub(Hub::with_typing_ttl(ttl))
        .build();

    let (alice_ticket, _alice_id) = user_ticket(&store, "alice").await;
    let (bob_ticket, _bob_id) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_typing(&mut alice_ws, &channel.id.to_string()).await;
    next_of_type(&mut bob_ws, "typing.started", &channel.id.to_string()).await;

    // Refresh at t=300ms (comfortably before the original 400ms deadline),
    // which pushes the real deadline out to roughly t=700ms.
    tokio::time::sleep(Duration::from_millis(300)).await;
    send_typing(&mut alice_ws, &channel.id.to_string()).await;

    // Nothing should arrive for a good while, out to t=650ms; see this test's
    // doc comment for why that window proves both halves.
    let nothing = tokio::time::timeout(Duration::from_millis(350), read_frame(&mut bob_ws)).await;
    assert!(
        nothing.is_err(),
        "a refresh must neither repeat the start nor let the old deadline stop it early, \
         but got {nothing:?}"
    );
}

/// Typing is rate limited: sending far more refreshes than the class budget
/// allows, in a tight loop across enough distinct channels that each would
/// otherwise be a fresh `typing.started`, still caps how many actually fan
/// out.
#[tokio::test]
async fn typing_is_rate_limited() {
    let (store, _guard) = support::new_store("slimm-typing-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();

    let (alice_ticket, _alice_id) = user_ticket(&store, "alice").await;
    let (bob_ticket, _bob_id) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    // More distinct channels than the burst budget, each one a fresh (never
    // seen) typing state, so every accepted refresh would fan out.
    let mut channel_ids = Vec::new();
    for i in 0..15 {
        let channel = store
            .create_channel(&format!("channel-{i}"), "text")
            .await
            .unwrap();
        channel_ids.push(channel.id.to_string());
    }

    for channel_id in &channel_ids {
        send_typing(&mut alice_ws, channel_id).await;
    }

    // Count how many `typing.started` frames actually arrive in a bounded
    // window, across any channel.
    let mut seen = 0usize;
    loop {
        let next = tokio::time::timeout(Duration::from_millis(500), read_frame(&mut bob_ws)).await;
        match next {
            Ok(frame) if frame["type"] == "typing.started" => seen += 1,
            Ok(_) => {}
            Err(_) => break,
        }
    }

    assert!(
        seen >= 1,
        "at least the burst-allowed refreshes get through"
    );
    assert!(
        seen < channel_ids.len(),
        "the rate limiter must refuse some of {} rapid refreshes, only {seen} got through",
        channel_ids.len()
    );
}

/// A user appearing offline does not have their typing announced to a channel.
///
/// Typing carries the typist's id to every viewer, so it is a second way to
/// learn someone is online, and it bypassed the appear-offline choke point:
/// a hidden user's keystrokes announced them. The frame is dropped per viewer
/// now, through the same status function every other presence surface uses.
#[tokio::test]
async fn a_hidden_user_typing_is_not_announced() {
    use slimm_server::presence::Visibility;
    let (store, _guard) = support::new_store("slimm-typing-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();

    let (alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (bob_ticket, _bob_id) = user_ticket(&store, "bob").await;
    store
        .set_presence_visibility(alice_id, Visibility::Hidden)
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_typing(&mut alice_ws, &channel.id.to_string()).await;

    assert_nothing_of_type(&mut bob_ws, "typing.started", &channel.id.to_string()).await;
}

/// A typing signal must not announce someone whose presence the store failed
/// to resolve, not just someone genuinely hidden: `presence_status` used to
/// collapse a real store error into the same `None` as "no such column",
/// which the typing gate read as "not offline" and let through.
///
/// The `presence_visibility` column is renamed out from under the query
/// rather than closing the whole pool: closing the pool also fails the
/// sender's own permission check before anything fans out, which would pass
/// this test for the wrong reason. Renaming only the one column this store
/// method reads leaves every other query, including that permission check,
/// working exactly as before.
#[tokio::test]
async fn a_store_error_resolving_presence_withholds_typing() {
    let (store, pool, _guard) = new_store_with_pool().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();

    let (alice_ticket, _alice_id) = user_ticket(&store, "alice").await;
    let (bob_ticket, _bob_id) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;

    // Broken before anyone connects so the visibility cache never loads and authorize falls through to the erroring store - the genuine fail-closed case (a cache hit resolves it correctly; see the presence unit tests).
    sqlx::query(
        "ALTER TABLE users RENAME COLUMN presence_visibility TO presence_visibility_broken",
    )
    .execute(&pool)
    .await
    .expect("break the column the store queries by name");

    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_typing(&mut alice_ws, &channel.id.to_string()).await;

    assert_nothing_of_type(&mut bob_ws, "typing.started", &channel.id.to_string()).await;
}
