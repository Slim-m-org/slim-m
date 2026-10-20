// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A real router with push enabled, a capturing relay, and a device key that
//! can unseal what reaches it: shared by the push envelope test binaries.
#![allow(dead_code)]

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
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tower::ServiceExt;

/// Deliberately long and unlike anything else on the wire, so a substring
/// search for them cannot collide by chance with base64 ciphertext, a uuid,
/// or a field name.
pub const SENTINEL_BODY: &str = "zzqx-secret-message-body-nobody-else-may-read-zzqx";
pub const SENTINEL_SENDER: &str = "Zzqx Sentinel Sender Displayname";
pub const SENTINEL_CHANNEL: &str = "zzqx-sentinel-channel-name";

pub struct World {
    pub app: Router,
    /// The same store the router holds, so a test can seed extra accounts
    /// after construction. Cheap to clone: it is a pool handle.
    pub store: Store,
    pub channel_id: slimm_server::ids::ChannelId,
    pub author_token: String,
    pub captured: std::sync::Arc<Mutex<Option<Value>>>,
    pub _guard: crate::support::TestDbGuard,
}

pub async fn world() -> World {
    let (path, guard) = crate::support::TestDbGuard::new("slimm-push-content-envelope-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool);
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store
        .create_channel(SENTINEL_CHANNEL, "text")
        .await
        .unwrap();

    let (captured, relay_url) = spawn_capturing_relay().await;
    let push = PushSender::with_debounce_window_ms(
        &Config {
            port: 0,
            database_path: String::new(),
            hash_concurrency: 2,
            push_relay_url: Some(relay_url),
            push_relay_key: Some("test-relay-key".to_owned()),
            ..Config::default()
        },
        50,
    )
    .expect("push sender");

    let app = crate::support::app::builder(store.clone())
        .push(push)
        .router();

    let author_token = account(&store, "author", SENTINEL_SENDER).await;
    World {
        app,
        store,
        channel_id: channel.id,
        author_token,
        captured,
        _guard: guard,
    }
}

/// An account with a session, built through the store: joining a claimed
/// deployment is an invite-gated policy decision pinned by its own tests, and
/// these only need somebody signed in.
pub async fn account(store: &Store, username: &str, display_name: &str) -> String {
    let account = store
        .create_account(username, display_name, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "phone")
        .await
        .unwrap()
        .access_token
}

pub fn request(
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

/// Registers a real device keypair over the real `PUT /push` route, so what is
/// sealed downstream is sealed to a key this "device" holds and can unseal.
pub async fn register_push(
    app: &Router,
    token: &str,
    push_token: &str,
    include_content: bool,
) -> SecretKey {
    let secret = SecretKey::generate(&mut OsRng.unwrap_err());
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/push",
            Some(token),
            Some(json!({
                "platform": "ios",
                "push_token": push_token,
                "push_public_key": BASE64.encode(secret.public_key().as_bytes()),
                "include_content": include_content,
                "include_content_chosen": true,
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::NO_CONTENT);
    secret
}

pub async fn spawn_capturing_relay() -> (std::sync::Arc<Mutex<Option<Value>>>, String) {
    let captured = std::sync::Arc::new(Mutex::new(None));
    let router = Router::new()
        .route(
            "/v1/send",
            post(
                |State(captured): State<std::sync::Arc<Mutex<Option<Value>>>>,
                 Json(body): Json<Value>| async move {
                    let messages = body["messages"].as_array().cloned().unwrap_or_default();
                    let results: Vec<Value> = messages
                        .iter()
                        .map(|m| json!({ "token": m["token"], "status": "delivered" }))
                        .collect();
                    *captured.lock().await = Some(body);
                    Json(json!({ "results": results }))
                },
            ),
        )
        .with_state(captured.clone());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    (captured, format!("http://{addr}"))
}

/// This crate cannot reach `slimm_server::store::now_ms`, which is
/// `pub(crate)`, so the same clock read is duplicated here for one assertion.
pub fn epoch_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("after the epoch")
        .as_millis() as i64
}

pub async fn wait_for_capture(captured: &Mutex<Option<Value>>) -> Value {
    crate::support::wait::wait_for("the relay to be called", || async {
        captured.lock().await.clone()
    })
    .await
}

pub async fn send(world: &World, content: &str) {
    let response = world
        .app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages", world.channel_id),
            Some(&world.author_token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": content })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::OK);
}

pub fn entry_for<'a>(body: &'a Value, token: &str) -> &'a Value {
    body["messages"]
        .as_array()
        .expect("messages array")
        .iter()
        .find(|m| m["token"] == token)
        .unwrap_or_else(|| panic!("no relay-bound entry for {token:?}"))
}

/// Unseals one entry's payload with the device's own key and returns the
/// envelope as JSON, which is the only way to read it - exactly the position
/// the relay is in, minus the key.
pub fn unseal(entry: &Value, secret: &SecretKey) -> Value {
    let sealed = BASE64
        .decode(entry["payload"].as_str().expect("payload is a string"))
        .expect("payload is valid base64");
    let plaintext = secret.unseal(&sealed).expect("unseals with the device key");
    serde_json::from_slice(&plaintext).expect("the envelope is JSON")
}
