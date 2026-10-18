// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot's watch session: durable state a member reads over REST, and the
//! tick it fans out on the ephemeral channel. See
//! docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.

use std::time::Duration;

use axum::http::StatusCode;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http;
use slimm_server::hub::Event;
use slimm_server::ids::ChannelId;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod support;

use support::watch_world::{World, call, film, session_uri, world};

#[tokio::test]
async fn a_member_reads_the_position_the_bot_set_from_rest_alone() {
    let w = world().await;
    let uri = session_uri(w.voice);
    let (none, _) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(none, StatusCode::NOT_FOUND);

    let (set, _) = call(&w, "PUT", &uri, &w.bot, Some(film(5_025_000, true))).await;
    assert_eq!(set, StatusCode::NO_CONTENT);

    let (status, body) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["title"], "A Film");
    assert_eq!(body["position_ms"], 5_025_000);
    assert_eq!(body["playing"], true);
    assert!(body["epoch"].as_i64().unwrap() > 0);
    assert_eq!(body["ttl_ms"], slimm_server::store::WATCH_SESSION_TTL_MS);
    assert_eq!(body["duration_ms"], 5_400_000);
    assert!(body["server_time_ms"].as_i64().unwrap() >= body["sampled_at_ms"].as_i64().unwrap());
}

#[tokio::test]
async fn the_epoch_changes_on_a_seek_or_a_new_title_and_not_on_a_plain_pause() {
    let w = world().await;
    let uri = session_uri(w.voice);
    let epoch = |body: &Value| body["epoch"].as_i64().unwrap();
    call(&w, "PUT", &uri, &w.bot, Some(film(1_000, true))).await;
    call(&w, "PUT", &uri, &w.bot, Some(film(2_000, false))).await;
    let (_, paused) = call(&w, "GET", &uri, &w.member, None).await;
    let first = epoch(&paused);

    let mut seek = film(60_000, false);
    seek["seeked"] = json!(true);
    call(&w, "PUT", &uri, &w.bot, Some(seek)).await;
    let (_, seeked) = call(&w, "GET", &uri, &w.member, None).await;
    assert!(epoch(&seeked) > first);

    let mut next = film(0, true);
    next["item_id"] = json!("item-2");
    call(&w, "PUT", &uri, &w.bot, Some(next)).await;
    let (_, retitled) = call(&w, "GET", &uri, &w.member, None).await;
    assert!(epoch(&retitled) > epoch(&seeked));
}

#[tokio::test]
async fn a_tick_rides_the_ephemeral_channel_only_and_moves_the_durable_position() {
    let w = world().await;
    let uri = session_uri(w.voice);
    call(&w, "PUT", &uri, &w.bot, Some(film(1_000, true))).await;
    let mut durable = w.state.hub.subscribe();
    let mut ephemeral = w.state.hub.subscribe_ephemeral();

    let (status, _) = call(
        &w,
        "POST",
        &format!("{uri}/tick"),
        &w.bot,
        Some(json!({ "playing": true, "position_ms": 6_000 })),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    match ephemeral.try_recv().unwrap() {
        Event::WatchTick {
            channel_id,
            position_ms,
            playing,
            epoch,
            ended,
            ..
        } => {
            assert_eq!(channel_id, w.voice);
            assert_eq!(position_ms, 6_000);
            assert!(playing);
            assert!(epoch > 0);
            assert!(!ended);
        }
        other => panic!("expected a watch tick, got {other:?}"),
    }
    assert!(
        durable.try_recv().is_err(),
        "a tick must not ride the durable channel"
    );

    let (_, body) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(body["position_ms"], 6_000);
}

#[tokio::test]
async fn only_a_bot_writes_and_only_to_a_voice_channel() {
    let w = world().await;
    let uri = session_uri(w.voice);
    let (by_member, _) = call(&w, "PUT", &uri, &w.member, Some(film(0, true))).await;
    assert_eq!(by_member, StatusCode::FORBIDDEN);
    let (tick_by_member, _) = call(
        &w,
        "POST",
        &format!("{uri}/tick"),
        &w.member,
        Some(json!({ "playing": true, "position_ms": 0 })),
    )
    .await;
    assert_eq!(tick_by_member, StatusCode::FORBIDDEN);
    let (in_text, _) = call(&w, "PUT", &session_uri(w.text), &w.bot, Some(film(0, true))).await;
    assert_eq!(in_text, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_live_session_is_not_taken_over_and_only_its_bot_can_end_it() {
    let w = world().await;
    let uri = session_uri(w.voice);
    call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;
    let (taken, _) = call(&w, "PUT", &uri, &w.other_bot, Some(film(0, true))).await;
    assert_eq!(taken, StatusCode::CONFLICT);
    let (foreign_end, _) = call(&w, "DELETE", &uri, &w.other_bot, None).await;
    assert_eq!(foreign_end, StatusCode::NOT_FOUND);
    let (ended, _) = call(&w, "DELETE", &uri, &w.bot, None).await;
    assert_eq!(ended, StatusCode::NO_CONTENT);
    let (gone, _) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(gone, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_session_nobody_refreshed_reads_as_ended_and_can_be_replaced() {
    let w = world().await;
    let uri = session_uri(w.voice);
    call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;
    let stale = slimm_server::store::WATCH_SESSION_TTL_MS + 1_000;
    sqlx::query("UPDATE watch_sessions SET sampled_at = sampled_at - ?")
        .bind(stale)
        .execute(&w.pool)
        .await
        .unwrap();
    let (status, _) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (tick, _) = call(
        &w,
        "POST",
        &format!("{uri}/tick"),
        &w.bot,
        Some(json!({ "playing": true, "position_ms": 1 })),
    )
    .await;
    assert_eq!(tick, StatusCode::NOT_FOUND);
    let (replaced, _) = call(&w, "PUT", &uri, &w.other_bot, Some(film(0, true))).await;
    assert_eq!(replaced, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn hostile_input_is_refused() {
    let w = world().await;
    let uri = session_uri(w.voice);
    let (status, _) = call(&w, "PUT", &uri, &w.bot, Some(film(-1, true))).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let mut untitled = film(0, true);
    untitled["title"] = json!("   ");
    let (status, _) = call(&w, "PUT", &uri, &w.bot, Some(untitled)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let mut hidden = film(0, true);
    hidden["title"] = json!("a\u{202e}b");
    let (status, _) = call(&w, "PUT", &uri, &w.bot, Some(hidden)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(w: &World, addr: std::net::SocketAddr, token: &str) -> Client {
    let ctx = w.state.store.authenticate(token).await.unwrap().unwrap();
    let (ticket, _) = w.state.store.mint_ws_ticket(&ctx).await.unwrap();
    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    let hello = json!({ "type": "hello", "ticket": ticket, "protocol": 1 });
    ws.send(WsMessage::Text(hello.to_string())).await.unwrap();
    let ack = next_frame(&mut ws).await;
    assert_eq!(ack["type"], "hello");
    ws
}

async fn next_frame(ws: &mut Client) -> Value {
    loop {
        if let Some(Ok(WsMessage::Text(text))) = ws.next().await {
            return serde_json::from_str(text.as_str()).unwrap();
        }
    }
}

fn tick_for(channel_id: ChannelId) -> Event {
    Event::WatchTick {
        channel_id,
        bot_user_id: slimm_server::ids::UserId::generate(),
        ended: false,
        item_id: "item-1".to_owned(),
        playing: true,
        position_ms: 7_000,
        sampled_at_ms: 1,
        epoch: 1,
    }
}

#[tokio::test]
async fn a_tick_reaches_a_viewer_of_the_channel_and_nobody_else() {
    let w = world().await;
    let private = w
        .state
        .store
        .create_channel_with_id(
            ChannelId::generate(),
            "private-lounge",
            "voice",
            None,
            Some(w.alice),
            Default::default(),
        )
        .await
        .unwrap()
        .channel
        .id;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = http::router(w.state.clone());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let mut alice = connect(&w, addr, &w.member).await;
    let mut bob = connect(&w, addr, &w.bob).await;

    w.state.hub.publish(tick_for(private));
    w.state.hub.publish(tick_for(w.voice));

    let frame = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let f = next_frame(&mut alice).await;
            if f["type"] == "watch.tick" && f["channel_id"] == private.to_string() {
                return f;
            }
        }
    })
    .await
    .expect("a viewer of the private channel gets the tick");
    assert_eq!(frame["position_ms"], 7_000);
    assert_eq!(frame["playing"], true);
    assert_eq!(frame["epoch"], 1);

    let seen = tokio::time::timeout(Duration::from_millis(500), async {
        loop {
            let f = next_frame(&mut bob).await;
            if f["type"] == "watch.tick" {
                return f;
            }
        }
    })
    .await
    .expect("bob sees the public channel's tick");
    assert_eq!(seen["channel_id"], w.voice.to_string());
}
