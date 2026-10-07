// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A message push skips an account that is actively using another device, for
//! a short window after its last activity report.

use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::{MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::presence::PresenceTracker;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
use slimm_server::viewing::ACTIVE_WINDOW;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod support;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-push-active-elsewhere");
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

async fn seed_everyone(store: &Store) {
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
}

async fn account(store: &Store, name: &str) -> (UserId, String) {
    let user = store.create_user(name, name).await.unwrap();
    let tokens = store.open_session(user.id, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    (user.id, ticket)
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
    loop {
        if let Some(Ok(WsMessage::Text(text))) = ws.next().await {
            let frame: Value = serde_json::from_str(text.as_str()).unwrap();
            if frame["type"] == "hello" {
                return ws;
            }
        }
    }
}

async fn wait_until(mut done: impl FnMut() -> bool) {
    for _ in 0..200 {
        if done() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("condition never held");
}

#[tokio::test]
async fn push_skips_a_recipient_active_on_another_device_until_the_window_ends() {
    let (store, _guard) = new_store().await;
    seed_everyone(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let author = store.create_user("author", "Author").await.unwrap().id;
    let active = store.create_user("active", "Active").await.unwrap().id;
    let lapsed = store.create_user("lapsed", "Lapsed").await.unwrap().id;
    let away = store.create_user("away", "Away").await.unwrap().id;
    let sent = store
        .send_message(NewMessage::plain(
            channel.id,
            author,
            MessageId::generate(),
            "hi",
        ))
        .await
        .unwrap();

    let viewing = PresenceTracker::new().viewing();
    viewing.mark_active(active, 1);
    viewing.mark_active_at(
        lapsed,
        2,
        Instant::now() - ACTIVE_WINDOW - Duration::from_secs(1),
    );

    let kept = slimm_server::push::narrow_for_attention(
        &store,
        channel.id,
        sent.message.seq,
        &viewing,
        vec![active, lapsed, away],
    )
    .await
    .unwrap();
    assert_eq!(kept, vec![lapsed, away]);
}

#[tokio::test]
async fn an_active_viewing_frame_counts_even_with_no_channel_open_and_ends_with_the_socket() {
    let (store, _guard) = new_store().await;
    seed_everyone(&store).await;
    let state = state_for(&store);
    let (alice, ticket) = account(&store, "alice").await;
    let addr = serve(state.clone()).await;
    let mut ws = connect(addr, &ticket).await;
    let viewing = state.hub.presence().viewing();

    let idle = json!({ "type": "viewing", "channel_ids": [] });
    ws.send(WsMessage::Text(idle.to_string())).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(
        !viewing.is_recently_active(alice),
        "a frame without active is not activity"
    );

    let active = json!({ "type": "viewing", "channel_ids": [], "active": true });
    ws.send(WsMessage::Text(active.to_string())).await.unwrap();
    wait_until(|| viewing.is_recently_active(alice)).await;

    ws.close(None).await.unwrap();
    drop(ws);
    wait_until(|| !viewing.is_recently_active(alice)).await;
}
