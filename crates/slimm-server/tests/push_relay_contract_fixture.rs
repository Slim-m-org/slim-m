// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Generates the cross-repo push-envelope contract fixture.
//!
//! The relay lives in a different repository and language
//! (slim-m-relay/internal/api/push_relay_contract_test.go), so nothing short
//! of actually running both sides catches one drifting out from under the
//! other. This test captures the literal JSON bodies slimm-server's real
//! relay client POSTs to `/v1/send` for two genuine message sends - one to
//! an iOS-registered device, one to an Android-registered device, the whole
//! platform vocabulary [`RegisterRequest`](slimm_server) accepts today -
//! driven through the full stack (store, HTTP handler,
//! [`slimm_server::push`], and a real `reqwest` client), so neither is ever
//! a re-serialization of the wire types against themselves.
//!
//! Four synthetic edge-case entries (a payload at and just over the relay's
//! documented 4096-byte limit, an unknown `kind`, and an unknown `platform`)
//! are appended in the same wire shape. Each is built by cloning one of the
//! two real entries above and overriding only the one or two fields that
//! case is actually about - a payload's length, or a deliberately-invalid
//! `kind` or `platform` - so every field not under test in a synthetic case
//! (`platform` and `kind` for the payload-boundary cases; `kind` for the
//! unknown-platform case; `platform` for the unknown-kind case) is a value
//! the server genuinely produced this run, not a literal retyped from
//! scratch that could quietly stop matching what `envelope.rs`/`relay.rs`
//! actually emit. This fixture only ever drives a message send, so `kind` is
//! always `"message"` in it; the other kinds (`mention`, `call`, `call_end`,
//! `security`) are captured by [`kinds`] into a sibling file, because the
//! relay's contract test counts the entries here against its own case table.
//! The relay must still reject an outright-unknown `kind` or `platform`, which
//! is exactly the failure mode this contract exists to close off before it
//! ships.
//!
//! Run standalone (`cargo test --all`), this test only asserts the two real
//! entries' own shape: it is not the relay-facing check. Exporting the
//! fixture for `TestPushRelayContract` to consume needs
//! `SLIMM_PUSH_CONTRACT_FIXTURE_OUT` set to a path inside a sibling
//! slim-m-relay checkout; the `push-relay-contract` workflow sets it.
//! Without it, the fixture is written under `CARGO_TARGET_TMPDIR` and
//! nothing else reads it, so this test costs nothing extra in the ordinary
//! `cargo test --all` run.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::time::Duration;

use axum::extract::State;
use axum::routing::post;
use axum::{Json, Router};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use crypto_box::SecretKey;
use crypto_box::aead::rand_core::{OsRng, TryRngCore};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tower::ServiceExt;

mod support;

#[path = "push_relay_contract_kinds/mod.rs"]
mod kinds;

/// The push tokens behind the fixture's two genuinely server-produced
/// entries, one per platform this server can register a device for today. A
/// token is otherwise opaque to the relay, so reusing it as each case's name
/// (matched against `contractCases` on the Go side) needs no separate
/// metadata channel.
const REAL_CASE_TOKEN_IOS: &str = "contract-real-message";
const REAL_CASE_TOKEN_ANDROID: &str = "contract-real-message-android";

/// Matches the relay's own `maxPayloadBytes` (internal/api/send.go). Kept
/// as a literal here, not imported from anywhere, deliberately: this test's
/// job is to notice if that literal and this one ever say something
/// different, not to assume they agree.
const RELAY_MAX_PAYLOAD_BYTES: usize = 4096;

fn app(store: Store, push: PushSender) -> Router {
    app_with_voice(
        store,
        push,
        slimm_server::voice::VoiceService::disabled(),
        Hub::new(),
    )
}

fn app_with_voice(
    store: Store,
    push: PushSender,
    voice: slimm_server::voice::VoiceService,
    hub: Hub,
) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).expect("auth service"),
        hub,
        limiter: RateLimiter::new(),
        push,
        voice,
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn request(
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

/// A member with a session, built straight through the store.
///
/// Deliberately not the `/auth/register` route: joining a claimed deployment
/// is an invite-gated policy decision, and it is pinned by its own tests in
/// `registration_gate.rs`. These tests only need somebody signed in, so going
/// through the store keeps them independent of that policy.
async fn register_user(store: &Store, username: &str) -> String {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    // The first account through here claims the deployment, exactly as the
    // first real registration does; later ones find it already set up.
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

/// Registers a real device keypair for push over HTTP, exactly the request
/// shape a client sends, so what gets sealed downstream is sealed to a key
/// the "device" (this test) actually holds and can unseal. `platform` is
/// "ios" or "android" - [`http::push`](slimm_server)'s `RegisterRequest`
/// accepts nothing else - so the caller picks which of the relay's two
/// platforms this device's real, later-captured entry will exercise.
async fn register_push(
    app: &Router,
    token: &str,
    platform: &str,
    push_token: &str,
    include_content: bool,
    voip_push_token: Option<&str>,
) -> SecretKey {
    let secret = SecretKey::generate(&mut OsRng.unwrap_err());
    let public = secret.public_key();
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/push",
            Some(token),
            Some(json!({
                "platform": platform,
                "push_token": push_token,
                "voip_push_token": voip_push_token,
                "push_public_key": BASE64.encode(public.as_bytes()),
                "include_content": include_content,
                "include_content_chosen": true,
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::NO_CONTENT);
    secret
}

async fn seeded_store() -> (Store, slimm_server::ids::ChannelId, support::TestDbGuard) {
    let (store, guard) = support::new_store("slimm-push-contract-fixture-test").await;
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

/// A real HTTP server on an ephemeral loopback port standing in for the
/// relay, capturing the one `/v1/send` body it receives so the test can
/// inspect exactly what `slimm_server::push` put on the wire. Reports
/// everything delivered: this fixture only needs the outbound request, not
/// the response-handling paths `tests/push_endpoints.rs` already covers.
async fn spawn_capturing_relay() -> (std::sync::Arc<Mutex<Option<Value>>>, String) {
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

async fn wait_for_capture(captured: &Mutex<Option<Value>>) -> Value {
    let start = std::time::Instant::now();
    loop {
        if let Some(body) = captured.lock().await.clone() {
            return body;
        }
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "the relay was never called"
        );
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

/// Finds the one captured message bound for `token`, by value so the caller
/// can go on to build synthetic entries from it without fighting borrows
/// against the shared `messages` slice.
fn find_entry(messages: &[Value], token: &str) -> Value {
    messages
        .iter()
        .find(|m| m["token"] == token)
        .unwrap_or_else(|| panic!("no captured relay-bound entry for token {token:?}"))
        .clone()
}

/// Asserts a genuinely server-produced entry has exactly the shape the relay
/// contract requires: the real `platform` and `token` requested, `kind`
/// still `"message"` (all `PushKind` encodes today), a `payload` that
/// unseals with the device's own key, and nothing else - a field rename or
/// an extra field fails right here, in server CI, before it ever reaches the
/// relay.
///
/// `want_content` is what this device asked for at registration, checked
/// against the *unsealed* envelope. That the outer key set is identical
/// either way is the point: opting into content changes what is inside the
/// sealed box and nothing the relay can see, so a change that ever hoisted a
/// preview field outside the seal fails the key-set assertion below.
fn assert_real_entry_shape(
    entry: &Value,
    want_platform: &str,
    want_token: &str,
    secret: &SecretKey,
    want_content: bool,
) {
    assert_eq!(entry["platform"], want_platform);
    assert_eq!(entry["token"], want_token);
    assert_eq!(entry["kind"], "message");
    let payload = entry["payload"].as_str().expect("payload is a JSON string");
    assert!(
        payload.len() <= RELAY_MAX_PAYLOAD_BYTES,
        "a real payload must fit the relay's own limit, was {}",
        payload.len()
    );
    let sealed = BASE64.decode(payload).expect("payload is valid base64");
    let plaintext = secret
        .unseal(&sealed)
        .expect("payload unseals with the device's own key");
    let envelope: Value = serde_json::from_slice(&plaintext).expect("the sealed envelope is JSON");
    for field in ["sender", "body"] {
        assert_eq!(
            envelope.get(field).is_some(),
            want_content,
            "{field} should be {} in this device's envelope: {envelope}",
            if want_content { "present" } else { "absent" }
        );
    }
    let keys: BTreeSet<_> = entry
        .as_object()
        .expect("entry is a JSON object")
        .keys()
        .cloned()
        .collect();
    let expected_keys: BTreeSet<_> = ["kind", "payload", "platform", "token"]
        .into_iter()
        .map(String::from)
        .collect();
    assert_eq!(
        keys, expected_keys,
        "the relay-bound message must carry exactly these four fields, nothing more or less"
    );
}

/// Clones a genuinely server-produced entry and overrides only the named
/// fields, so a synthetic edge case's fields that are not the point of that
/// case (see the doc comment on [`push_relay_contract_fixture`]) stay
/// whatever the server actually emitted this run.
fn with_overrides(base: &Value, overrides: &[(&str, &str)]) -> Value {
    let mut entry = base.clone();
    let obj = entry.as_object_mut().expect("entry is a JSON object");
    for &(key, value) in overrides {
        obj.insert(key.to_owned(), json!(value));
    }
    entry
}

/// Where the fixture is written. The cross-repo `push-relay-contract`
/// workflow points this at a path inside its sibling slim-m-relay checkout;
/// left unset (every ordinary `cargo test`), it lands under the real Cargo
/// target directory, which is already gitignored, so a plain local test run
/// never leaves a stray file in the tree.
fn fixture_out_path() -> PathBuf {
    if let Ok(explicit) = std::env::var("SLIMM_PUSH_CONTRACT_FIXTURE_OUT") {
        return PathBuf::from(explicit);
    }
    PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("push_relay_contract.generated.json")
}

#[tokio::test]
async fn push_relay_contract_fixture() {
    let (store, channel_id, _guard) = seeded_store().await;
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

    let app = app(store.clone(), push);
    let alice_token = register_user(&store, "alice").await;
    let bob_token = register_user(&store, "bob").await;
    let carol_token = register_user(&store, "carol").await;
    // One device of each shape; see this test's own module doc for why.
    let bob_secret = register_push(&app, &bob_token, "ios", REAL_CASE_TOKEN_IOS, true, None).await;
    let carol_secret = register_push(
        &app,
        &carol_token,
        "android",
        REAL_CASE_TOKEN_ANDROID,
        false,
        None,
    )
    .await;

    let sent = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(&alice_token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hello" })),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), axum::http::StatusCode::OK);

    let captured_body = wait_for_capture(&captured).await;
    let messages = captured_body["messages"]
        .as_array()
        .expect("the captured body has a messages array");
    assert_eq!(
        messages.len(),
        2,
        "exactly bob's one device and carol's one device were targeted"
    );
    let ios_entry = find_entry(messages, REAL_CASE_TOKEN_IOS);
    let android_entry = find_entry(messages, REAL_CASE_TOKEN_ANDROID);

    // Self-check: the part of the contract slim-m alone can verify. A rename, a
    // dropped field or a changed kind/platform fails here, in server CI.
    assert_real_entry_shape(&ios_entry, "ios", REAL_CASE_TOKEN_IOS, &bob_secret, true);
    assert_real_entry_shape(
        &android_entry,
        "android",
        REAL_CASE_TOKEN_ANDROID,
        &carol_secret,
        false,
    );

    // Synthetic edge cases, cloned from a real entry and overridden only where
    // each case is about it (module doc); `TestPushRelayContract` rejects each.
    let at_limit_payload = "x".repeat(RELAY_MAX_PAYLOAD_BYTES);
    let over_limit_payload = "x".repeat(RELAY_MAX_PAYLOAD_BYTES + 1);
    let synthetic_entries = [
        with_overrides(
            &android_entry,
            &[
                ("token", "contract-payload-at-limit"),
                ("payload", &at_limit_payload),
            ],
        ),
        with_overrides(
            &android_entry,
            &[
                ("token", "contract-payload-over-limit"),
                ("payload", &over_limit_payload),
            ],
        ),
        with_overrides(
            &ios_entry,
            &[
                ("token", "contract-unknown-kind"),
                ("kind", "not-a-real-kind"),
            ],
        ),
        with_overrides(
            &android_entry,
            &[
                ("token", "contract-unknown-platform"),
                ("platform", "windows-phone"),
            ],
        ),
    ];

    let mut all_messages = vec![ios_entry, android_entry];
    all_messages.extend(synthetic_entries);
    let fixture = json!({ "messages": all_messages });

    let out_path = fixture_out_path();
    std::fs::create_dir_all(out_path.parent().expect("fixture path has a parent"))
        .expect("create the fixture's output directory");
    std::fs::write(
        &out_path,
        format!("{}\n", serde_json::to_string_pretty(&fixture).unwrap()),
    )
    .expect("write the push-relay contract fixture");
}
