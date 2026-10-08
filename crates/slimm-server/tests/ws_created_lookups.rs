// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A `message.created` frame's mentions and webhook label are read once per
//! message, not once per subscriber, and each subscriber still gets its own
//! `mentions_me`.
//!
//! Counts statements through a global tracing subscriber, one test per binary,
//! because sqlx emits its events on the connection's worker thread.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

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
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tracing::Subscriber;
use tracing::field::{Field, Visit};
use tracing_subscriber::Registry;
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};

mod support;

const SUBSCRIBERS: usize = 6;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

#[derive(Default)]
struct Counts {
    any: AtomicUsize,
    mention_reads: AtomicUsize,
    webhook_label_reads: AtomicUsize,
}

struct Statement(String);

impl Visit for Statement {
    fn record_debug(&mut self, _field: &Field, value: &dyn std::fmt::Debug) {
        self.0.push_str(&format!("{value:?} "));
    }
}

struct CountQueries(Arc<Counts>);

impl<S: Subscriber> Layer<S> for CountQueries {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        if event.metadata().target() != "sqlx::query" {
            return;
        }
        let mut statement = Statement(String::new());
        event.record(&mut statement);
        self.0.any.fetch_add(1, Ordering::Relaxed);
        let reads = statement.0.contains("SELECT");
        if reads && statement.0.contains("FROM message_mentions") {
            self.0.mention_reads.fetch_add(1, Ordering::Relaxed);
        }
        if reads && statement.0.contains("FROM webhook_message_usernames") {
            self.0.webhook_label_reads.fetch_add(1, Ordering::Relaxed);
        }
    }
}

async fn connect(addr: std::net::SocketAddr, ticket: &str) -> Client {
    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();
    assert_eq!(read_frame(&mut ws).await["type"], "hello");
    ws
}

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

#[tokio::test]
async fn mentions_and_the_webhook_label_are_read_once_for_every_subscriber() {
    let counts = Arc::new(Counts::default());
    tracing::subscriber::set_global_default(
        Registry::default().with(CountQueries(Arc::clone(&counts))),
    )
    .expect("no other subscriber in this binary");

    let (path, _guard) = support::TestDbGuard::new("slimm-ws-created-lookups");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let author = store.create_user("author", "Author").await.unwrap();
    let author_token = store
        .open_session(author.id, "device")
        .await
        .unwrap()
        .access_token;

    let state = AppState {
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
    };
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = http::router(state.clone());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });

    let mut watchers = Vec::new();
    for n in 0..SUBSCRIBERS {
        let user = store
            .create_user(&format!("w{n}"), &format!("W{n}"))
            .await
            .unwrap();
        let tokens = store.open_session(user.id, "device").await.unwrap();
        let ctx = store
            .authenticate(&tokens.access_token)
            .await
            .unwrap()
            .unwrap();
        let (ticket, _) = store.mint_ws_ticket(&ctx).await.unwrap();
        watchers.push(connect(addr, &ticket).await);
    }

    let mentions_before = counts.mention_reads.load(Ordering::Relaxed);
    let labels_before = counts.webhook_label_reads.load(Ordering::Relaxed);
    let response = reqwest::Client::new()
        .post(format!("http://{addr}/channels/{}/messages", channel.id))
        .bearer_auth(&author_token)
        .json(&json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hey @w0 and @w1" }))
        .send()
        .await
        .unwrap();
    assert!(
        response.status().is_success(),
        "send failed: {}",
        response.status()
    );

    for (n, ws) in watchers.iter_mut().enumerate() {
        let frame = read_frame(ws).await;
        assert_eq!(frame["type"], "message.created");
        assert_eq!(
            frame["message"]["mentions_me"],
            n < 2,
            "w{n} got the wrong mentions_me"
        );
    }
    assert!(
        counts.any.load(Ordering::Relaxed) > 0,
        "the counter saw no statement at all, so the bounds below prove nothing"
    );
    let mention_reads = counts.mention_reads.load(Ordering::Relaxed) - mentions_before;
    let label_reads = counts.webhook_label_reads.load(Ordering::Relaxed) - labels_before;
    assert!(
        mention_reads <= 1,
        "{SUBSCRIBERS} subscribers read message_mentions {mention_reads} times; once per message is the bound"
    );
    assert!(
        label_reads <= 1,
        "{SUBSCRIBERS} subscribers read webhook_message_usernames {label_reads} times; once per message is the bound"
    );
}
