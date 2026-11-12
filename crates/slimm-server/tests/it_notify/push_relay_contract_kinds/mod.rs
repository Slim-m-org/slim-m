// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One relay-bound entry per push kind other than `"message"`, each produced
//! by the server's own path for it: a mention in a channel, a DM ring and its
//! end, and a sign-in from a new device.
//!
//! The relay's contract test counts the entries in the main fixture against its
//! own case table, so these go in a sibling file
//! (`push_relay_contract_kinds.generated.json`) the relay can adopt on its own
//! schedule. Until it does, the shape checks below are what a wire-name drift
//! fails in server CI.

use std::collections::BTreeSet;
use std::sync::Arc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use crypto_box::SecretKey;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::store::Store;
use tokio::sync::Mutex;
use tower::ServiceExt;

use axum::extract::State;
use axum::routing::post as route_post;
use axum::{Json, Router};
use tokio::net::TcpListener;

use super::{
    RELAY_MAX_PAYLOAD_BYTES, app_with_voice, register_push, register_user, request, seeded_store,
};

const PASSWORD: &str = "correct horse battery staple";

/// Names each entry's device so a case can be found by what it is.
const TOKEN_MENTION: &str = "contract-kind-mention";
const TOKEN_CALL_ANDROID: &str = "contract-kind-call-android";
const TOKEN_CALL_IOS_VOIP: &str = "contract-kind-call-ios-voip";
const TOKEN_SECURITY: &str = "contract-kind-security";

pub(super) struct KindEntry {
    pub entry: Value,
    pub secret: SecretKey,
}

fn voice() -> slimm_server::voice::VoiceService {
    slimm_server::voice::VoiceService::for_test(
        "wss://livekit.example.com",
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    )
}

async fn post(app: &axum::Router, uri: &str, token: Option<&str>, body: Option<Value>) -> Value {
    let response = app
        .clone()
        .oneshot(request("POST", uri, token, body))
        .await
        .unwrap();
    assert!(
        response.status().is_success(),
        "{uri} answered {}",
        response.status()
    );
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

async fn login(app: &axum::Router, device_name: &str) -> String {
    let body = json!({
        "username": "dana",
        "password": PASSWORD,
        "device_name": device_name,
        "client_kind": "android",
    });
    let response = post(app, "/auth/login", None, Some(body)).await;
    response["access_token"].as_str().unwrap().to_owned()
}

async fn wait_for_entries(
    captured: &Arc<Mutex<Vec<Value>>>,
    kind: &str,
    want: usize,
) -> Vec<Value> {
    crate::support::wait::wait_for(&format!("{want} {kind:?} entries at the relay"), || async {
        let found: Vec<Value> = captured
            .lock()
            .await
            .iter()
            .filter(|m| m["kind"] == kind)
            .cloned()
            .collect();
        (found.len() >= want).then_some(found)
    })
    .await
}

fn only(entries: &[Value], token: &str) -> Value {
    let mut matching = entries.iter().filter(|m| m["token"] == token);
    let entry = matching
        .next()
        .unwrap_or_else(|| panic!("no entry for {token:?}: {entries:?}"))
        .clone();
    assert!(matching.next().is_none(), "two entries for {token:?}");
    entry
}

/// A genuinely server-produced entry has exactly the relay's four fields, the
/// wire name the relay's `parseKind` accepts, a payload inside its limit, and
/// a sealed envelope of the kind the device will act on. A mention is the one
/// place the two differ: the relay alerts it as a mention, the device reads it
/// as the message it is.
pub(super) fn assert_kind_entry(
    entry: &Value,
    want_kind: &str,
    want_platform: &str,
    want_inner_kind: &str,
    secret: &SecretKey,
) {
    assert_eq!(entry["kind"], want_kind);
    assert_eq!(entry["platform"], want_platform);
    let keys: BTreeSet<_> = entry.as_object().unwrap().keys().cloned().collect();
    let expected: BTreeSet<_> = ["kind", "payload", "platform", "token"]
        .into_iter()
        .map(String::from)
        .collect();
    assert_eq!(keys, expected, "{want_kind}: the entry's fields changed");
    let payload = entry["payload"].as_str().expect("payload is a string");
    assert!(
        payload.len() <= RELAY_MAX_PAYLOAD_BYTES,
        "{want_kind}: payload is {} bytes",
        payload.len()
    );
    let sealed = BASE64.decode(payload).expect("payload is base64");
    let plaintext = secret.unseal(&sealed).expect("payload unseals");
    let envelope: Value = serde_json::from_slice(&plaintext).expect("envelope is JSON");
    assert_eq!(
        envelope["kind"], want_inner_kind,
        "{want_kind}: the sealed envelope names another kind: {envelope}"
    );
}

/// Drives each path once against a relay that records everything it is sent.
pub(super) async fn capture_kind_entries() -> Vec<KindEntry> {
    let (store, channel_id, _guard) = seeded_store().await;
    let (captured, relay_url) = spawn_all_capturing_relay().await;
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
    let app = app_with_voice(store.clone(), push, voice(), Hub::new());

    let (caller_token, _) = register_user_with_id(&store, "caller").await;
    let (callee_token, callee_user) = register_user_with_id(&store, "callee").await;
    let callee_id = callee_user.0.to_string();
    let mention_secret =
        register_push(&app, &callee_token, "android", TOKEN_MENTION, true, None).await;
    post(
        &app,
        &format!("/channels/{channel_id}/messages"),
        Some(&caller_token),
        Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hi @callee" })),
    )
    .await;
    let mention = only(
        &wait_for_entries(&captured, "mention", 1).await,
        TOKEN_MENTION,
    );

    // The same callee on a second device, since each session holds one registration: FCM, and the iOS VoIP token.
    let ios_session = store
        .open_session(callee_user, "ios-phone")
        .await
        .unwrap()
        .access_token;
    let call_android = register_push(
        &app,
        &callee_token,
        "android",
        TOKEN_CALL_ANDROID,
        true,
        None,
    )
    .await;
    let call_ios = register_push(
        &app,
        &ios_session,
        "ios",
        "contract-kind-call-ios-apns",
        true,
        Some(TOKEN_CALL_IOS_VOIP),
    )
    .await;
    let dm = post(
        &app,
        &format!("/dms/{callee_id}"),
        Some(&caller_token),
        None,
    )
    .await;
    let dm = dm["channel_id"].as_str().unwrap().to_owned();
    post(
        &app,
        &format!("/channels/{dm}/voice/ring"),
        Some(&caller_token),
        None,
    )
    .await;
    let rings = wait_for_entries(&captured, "call", 2).await;
    let call_android_entry = only(&rings, TOKEN_CALL_ANDROID);
    let call_ios_entry = only(&rings, TOKEN_CALL_IOS_VOIP);
    post(
        &app,
        &format!("/channels/{dm}/voice/ring/decline"),
        Some(&callee_token),
        None,
    )
    .await;
    let call_end = only(
        &wait_for_entries(&captured, "call_end", 1).await,
        TOKEN_CALL_ANDROID,
    );

    let hash = Auth::new(2)
        .unwrap()
        .hash_password(PASSWORD.to_owned())
        .await
        .unwrap();
    store.create_account("dana", "dana", &hash).await.unwrap();
    let pixel = login(&app, "Pixel").await;
    let security_secret = register_push(&app, &pixel, "android", TOKEN_SECURITY, true, None).await;
    login(&app, "Borrowed laptop").await;
    let security = only(
        &wait_for_entries(&captured, "security", 1).await,
        TOKEN_SECURITY,
    );

    vec![
        KindEntry {
            entry: mention,
            secret: mention_secret,
        },
        KindEntry {
            entry: call_android_entry,
            secret: call_android.clone(),
        },
        KindEntry {
            entry: call_ios_entry,
            secret: call_ios,
        },
        KindEntry {
            entry: call_end,
            secret: call_android,
        },
        KindEntry {
            entry: security,
            secret: security_secret,
        },
    ]
}

async fn register_user_with_id(
    store: &Store,
    username: &str,
) -> (String, slimm_server::ids::UserId) {
    let token = register_user(store, username).await;
    let id = store
        .live_user_id_by_username(username)
        .await
        .unwrap()
        .expect("the account was just created");
    (token, id)
}

/// Like [`spawn_capturing_relay`], but keeps every entry of every request, so
/// a test driving several pushes can pick each out by kind and token.
async fn spawn_all_capturing_relay() -> (std::sync::Arc<Mutex<Vec<Value>>>, String) {
    let captured = std::sync::Arc::new(Mutex::new(Vec::new()));
    let router = Router::new()
        .route(
            "/v1/send",
            route_post(
                |State(captured): State<std::sync::Arc<Mutex<Vec<Value>>>>,
                 Json(body): Json<Value>| async move {
                    let messages = body["messages"].as_array().cloned().unwrap_or_default();
                    let results: Vec<Value> = messages
                        .iter()
                        .map(|m| json!({ "token": m["token"], "status": "delivered" }))
                        .collect();
                    captured.lock().await.extend(messages);
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

#[tokio::test]
async fn push_relay_contract_kinds_fixture() {
    let entries = capture_kind_entries().await;
    let expected = [
        ("mention", "android", "message"),
        ("call", "android", "call"),
        ("call", "ios", "call"),
        ("call_end", "android", "call_end"),
        ("security", "android", "security"),
    ];
    assert_eq!(entries.len(), expected.len());
    for (captured, (kind, platform, inner)) in entries.iter().zip(expected) {
        assert_kind_entry(&captured.entry, kind, platform, inner, &captured.secret);
    }
    let fixture = json!({
        "messages": entries.iter().map(|e| e.entry.clone()).collect::<Vec<_>>(),
    });
    let out_path =
        super::fixture_out_path().with_file_name("push_relay_contract_kinds.generated.json");
    std::fs::write(
        &out_path,
        format!("{}\n", serde_json::to_string_pretty(&fixture).unwrap()),
    )
    .expect("write the push-relay kinds fixture");
}
