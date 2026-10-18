// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The store, router, and mock relay `delivery.rs`'s tests share: a real HTTP
//! server on an ephemeral loopback port, so the sender under test exercises
//! its real HTTP client end to end; only APNs/FCM themselves are out of
//! reach here, which is exactly what the relay exists to abstract away.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::State;
use axum::routing::post;
use axum::{Json, Router};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use crypto_box::SecretKey;
use crypto_box::aead::rand_core::{OsRng, TryRngCore};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tower::ServiceExt;

pub(crate) const SHORT_DEBOUNCE_MS: i64 = 150;
pub(crate) const WAIT_TIMEOUT: Duration = Duration::from_secs(5);

async fn new_store() -> (Store, crate::support::TestDbGuard) {
    let (path, guard) = crate::support::TestDbGuard::new("slimm-push-endpoints-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

pub(crate) fn app(store: Store, push: PushSender) -> Router {
    app_with_voice(
        store,
        push,
        slimm_server::voice::VoiceService::disabled(),
        Hub::new(),
    )
}

/// [`app`] with a voice service and hub the caller keeps a handle on.
///
/// Ringing needs a configured SFU, and driving the ring sweep by hand needs the
/// same hub the router publishes through, neither of which [`app`] can hand
/// back. Only the missed-call test needs either, so this is the variant rather
/// than the default.
pub(crate) fn app_with_voice(
    store: Store,
    push: PushSender,
    voice: slimm_server::voice::VoiceService,
    hub: Hub,
) -> Router {
    crate::support::app::builder(store)
        .hub(hub)
        .push(push)
        .voice(voice)
        .router()
}

pub(crate) fn request(
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> axum::http::Request<axum::body::Body> {
    let mut builder = axum::http::Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(axum::body::Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(axum::body::Body::empty()).unwrap(),
    }
}

pub(crate) async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A member with a session, built straight through the store.
///
/// Deliberately not the `/auth/register` route: joining a claimed deployment
/// is an invite-gated policy decision, and it is pinned by its own tests in
/// `registration_gate.rs`. These tests only need somebody signed in, so going
/// through the store keeps them independent of that policy.
pub(crate) async fn register_user(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    // The first account through here claims the deployment, exactly as the first real registration does.
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

/// Generates a device keypair and registers it for push over HTTP. Returns
/// the device's secret key (kept only by the "device", never the server) so
/// the test can unseal what it eventually receives.
pub(crate) async fn register_push(app: &Router, token: &str, push_token: &str) -> SecretKey {
    let secret = SecretKey::generate(&mut OsRng.unwrap_err());
    let public = secret.public_key();
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/push",
            Some(token),
            Some(json!({
                "platform": "ios",
                "push_token": push_token,
                "push_public_key": BASE64.encode(public.as_bytes()),
                "include_content": false,
                "include_content_chosen": true,
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::NO_CONTENT);
    secret
}

/// Polls a synchronous condition until it is true or `timeout` elapses.
pub(crate) async fn wait_until<F>(mut check: F, timeout: Duration) -> bool
where
    F: FnMut() -> bool,
{
    let start = std::time::Instant::now();
    loop {
        if check() {
            return true;
        }
        if start.elapsed() > timeout {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

/// [`wait_until`] for an async condition (a store query, for example).
pub(crate) async fn wait_until_async<F, Fut>(mut check: F, timeout: Duration) -> bool
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let start = std::time::Instant::now();
    loop {
        if check().await {
            return true;
        }
        if start.elapsed() > timeout {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

// --- Mock relay: a real HTTP server implementing just `POST /v1/send` ---

#[derive(Default)]
struct RelayState {
    calls: Vec<Value>,
    auth_headers: Vec<Option<String>>,
    status_overrides: HashMap<String, String>,
    /// Every POST increments this, whether or not it goes on to succeed, so a
    /// test can tell "the relay was reached" apart from "the relay delivered".
    attempts: usize,
    /// How many of the next calls should fail outright at the transport
    /// level (a 500), simulating a relay that is briefly unreachable.
    fail_next_calls: usize,
}

#[derive(Clone)]
pub(crate) struct MockRelay {
    state: Arc<Mutex<RelayState>>,
}

impl MockRelay {
    pub(crate) fn call_count(&self) -> usize {
        self.state.lock().unwrap().calls.len()
    }

    /// Every attempted POST, including ones that failed. Never smaller than
    /// [`Self::call_count`].
    pub(crate) fn attempt_count(&self) -> usize {
        self.state.lock().unwrap().attempts
    }

    /// Every message across every successful call, flattened, for asserting
    /// on payloads.
    pub(crate) fn all_messages(&self) -> Vec<Value> {
        self.state
            .lock()
            .unwrap()
            .calls
            .iter()
            .flat_map(|call| call["messages"].as_array().cloned().unwrap_or_default())
            .collect()
    }

    pub(crate) fn set_status(&self, token: &str, status: &str) {
        self.state
            .lock()
            .unwrap()
            .status_overrides
            .insert(token.to_owned(), status.to_owned());
    }

    /// The next `count` calls to `/v1/send` fail at the transport level
    /// instead of returning a result, so the caller sees a relay error rather
    /// than a per-token status.
    pub(crate) fn fail_next_calls(&self, count: usize) {
        self.state.lock().unwrap().fail_next_calls += count;
    }

    pub(crate) fn saw_bearer(&self, key: &str) -> bool {
        let expected = format!("Bearer {key}");
        self.state
            .lock()
            .unwrap()
            .auth_headers
            .iter()
            .all(|h| h.as_deref() == Some(expected.as_str()))
    }
}

async fn handle_send(
    State(mock): State<MockRelay>,
    headers: axum::http::HeaderMap,
    Json(body): Json<Value>,
) -> Result<Json<Value>, axum::http::StatusCode> {
    let auth_header = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);

    let mut state = mock.state.lock().unwrap();
    state.attempts += 1;
    if state.fail_next_calls > 0 {
        state.fail_next_calls -= 1;
        return Err(axum::http::StatusCode::INTERNAL_SERVER_ERROR);
    }

    let messages = body["messages"].as_array().cloned().unwrap_or_default();
    let results: Vec<Value> = messages
        .iter()
        .map(|m| {
            let token = m["token"].as_str().unwrap_or_default().to_owned();
            let status = state
                .status_overrides
                .get(&token)
                .cloned()
                .unwrap_or_else(|| "delivered".to_owned());
            json!({ "token": token, "status": status })
        })
        .collect();
    state.calls.push(body);
    state.auth_headers.push(auth_header);
    Ok(Json(json!({ "results": results })))
}

/// Spawns the mock relay on an ephemeral loopback port and returns a handle
/// plus its base URL (what `SLIMM_PUSH_RELAY_URL` would be set to).
pub(crate) async fn spawn_mock_relay() -> (MockRelay, String) {
    let mock = MockRelay {
        state: Arc::new(Mutex::new(RelayState::default())),
    };
    let router = Router::new()
        .route("/v1/send", post(handle_send))
        .with_state(mock.clone());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    (mock, format!("http://{addr}"))
}

pub(crate) fn push_config(relay_url: &str) -> Config {
    Config {
        port: 0,
        database_path: String::new(),
        hash_concurrency: 2,
        push_relay_url: Some(relay_url.to_owned()),
        push_relay_key: Some("test-relay-key".to_owned()),
        ..Config::default()
    }
}

/// Seeds `@everyone` with view+send so every registered user can see and post
/// to the general channel, matching the message-endpoint tests' setup.
pub(crate) async fn seeded_store() -> (
    Store,
    slimm_server::ids::ChannelId,
    crate::support::TestDbGuard,
) {
    let (store, guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    (store, channel.id, guard)
}
