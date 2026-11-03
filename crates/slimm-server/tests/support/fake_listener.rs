// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A stand-in for the call-audio listener: a real WebSocket server speaking
//! `listener/1`. It records every frame the server sends, so a test can check
//! each include set, and says whatever the test scripts it to.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use serde_json::{Value, json};
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};

pub const SECRET: &str = "0123456789abcdef0123456789abcdef";

#[derive(Default)]
struct Shared {
    received: Vec<Value>,
    outgoing: Option<UnboundedSender<Option<String>>>,
    connections: usize,
}

#[derive(Clone)]
struct Config {
    shared: Arc<Mutex<Shared>>,
    max_sessions: u32,
}

pub struct FakeListener {
    pub addr: SocketAddr,
    shared: Arc<Mutex<Shared>>,
}

impl FakeListener {
    pub async fn start(max_sessions: u32) -> Self {
        let shared = Arc::new(Mutex::new(Shared::default()));
        let config = Config {
            shared: Arc::clone(&shared),
            max_sessions,
        };
        let app = Router::new()
            .route("/v1/control", get(upgrade))
            .with_state(config);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await });
        Self { addr, shared }
    }

    pub fn url(&self) -> String {
        format!("ws://{}", self.addr)
    }

    /// Every frame the server has sent, oldest first.
    pub fn received(&self) -> Vec<Value> {
        self.shared.lock().unwrap().received.clone()
    }

    pub fn of_type(&self, kind: &str) -> Vec<Value> {
        self.received()
            .into_iter()
            .filter(|f| f["type"] == kind)
            .collect()
    }

    /// The include set of every `start` and `include` frame, in order.
    pub fn include_sets(&self) -> Vec<Vec<String>> {
        self.received()
            .iter()
            .filter(|f| f["type"] == "start" || f["type"] == "include")
            .map(|f| {
                let mut set: Vec<String> = f["include"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| v.as_str().unwrap().to_owned())
                    .collect();
                set.sort();
                set
            })
            .collect()
    }

    pub fn connections(&self) -> usize {
        self.shared.lock().unwrap().connections
    }

    fn say(&self, frame: Value) {
        let mut frame = frame;
        frame["v"] = json!(1);
        let outgoing = self.shared.lock().unwrap().outgoing.clone();
        if let Some(outgoing) = outgoing {
            let _ = outgoing.send(Some(frame.to_string()));
        }
    }

    pub fn segment(&self, session: &str, identity: &str, text: &str) {
        self.say(
            json!({"type":"segment","session":session,"identity":identity,
            "start_ms":1000,"end_ms":2500,"text":text,"language":"en"}),
        );
    }

    pub fn ended(&self, session: &str, reason: &str) {
        self.say(json!({"type":"ended","session":session,"reason":reason}));
    }

    /// Closes the control connection from the listener's side.
    pub fn hang_up(&self) {
        let outgoing = self.shared.lock().unwrap().outgoing.take();
        if let Some(outgoing) = outgoing {
            let _ = outgoing.send(None);
        }
    }
}

async fn upgrade(
    State(config): State<Config>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    let ok = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        == Some(format!("Bearer {SECRET}").as_str());
    if !ok {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    ws.on_upgrade(move |socket| serve(config, socket))
}

async fn serve(config: Config, mut socket: WebSocket) {
    let (tx, mut rx) = unbounded_channel::<Option<String>>();
    {
        let mut shared = config.shared.lock().unwrap();
        shared.outgoing = Some(tx);
        shared.connections += 1;
    }
    let ready = json!({"v":1,"type":"ready","version":"test","engine":"fake","model":"fake.bin",
        "max_sessions":config.max_sessions});
    if socket.send(Message::text(ready.to_string())).await.is_err() {
        return;
    }
    loop {
        tokio::select! {
            incoming = socket.recv() => {
                let Some(Ok(message)) = incoming else { return };
                if let Message::Text(text) = message {
                    let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                    config.shared.lock().unwrap().received.push(frame);
                }
            }
            outgoing = rx.recv() => match outgoing {
                Some(Some(text)) => {
                    if socket.send(Message::text(text)).await.is_err() { return }
                }
                _ => return,
            }
        }
    }
}
