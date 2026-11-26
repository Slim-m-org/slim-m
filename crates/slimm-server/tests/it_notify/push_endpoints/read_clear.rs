// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reading a channel on one device pushes a content-free `read` to the account's other devices,
//! so a phone that is not running clears its notifications and corrects its badge.

use std::time::Duration;

use axum::Router;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use crypto_box::SecretKey;
use serde_json::{Value, json};
use slimm_server::ids::UserId;
use slimm_server::push::PushSender;
use tower::ServiceExt;

use crate::push_endpoints::call_signals::register_device;
use crate::push_endpoints::harness::{
    MockRelay, SHORT_DEBOUNCE_MS, WAIT_TIMEOUT, app, push_config, register_user, request,
    seeded_store, spawn_mock_relay, wait_until,
};

const WINDOW: Duration = Duration::from_millis(300);

struct World {
    app: Router,
    mock: MockRelay,
    channel_id: String,
    alice_token: String,
    desktop: String,
    phone: String,
    phone_secret: SecretKey,
    _guard: crate::support::TestDbGuard,
}

async fn world() -> World {
    let (store, channel, guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("push sender")
        .with_read_clear_window(WINDOW);
    let app = app(store.clone(), push);
    let (alice_token, _) = register_user(&store, "alice").await;
    let (desktop, bob_id) = register_user(&store, "bob").await;
    let bob = UserId(uuid::Uuid::parse_str(&bob_id).unwrap());
    let phone = store.open_session(bob, "phone").await.unwrap().access_token;
    register_device(&app, &desktop, "android", "desktop-fcm", None).await;
    let phone_secret = register_device(&app, &phone, "android", "phone-fcm", None).await;
    World {
        app,
        mock,
        channel_id: channel.to_string(),
        alice_token,
        desktop,
        phone,
        phone_secret,
        _guard: guard,
    }
}

impl World {
    async fn alice_says(&self, text: &str) -> i64 {
        let response = self
            .app
            .clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{}/messages", self.channel_id),
                Some(&self.alice_token),
                Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": text })),
            ))
            .await
            .unwrap();
        crate::push_endpoints::harness::json_body(response).await["seq"]
            .as_i64()
            .expect("the sent message has a seq")
    }

    async fn read(&self, token: &str, seq: i64) {
        let response = self
            .app
            .clone()
            .oneshot(request(
                "PUT",
                &format!("/channels/{}/read", self.channel_id),
                Some(token),
                Some(json!({ "seq": seq })),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
    }

    fn reads(&self) -> Vec<Value> {
        self.mock
            .all_messages()
            .into_iter()
            .filter(|m| m["kind"] == "read")
            .collect()
    }

    async fn wait_for_reads(&self, count: usize) -> Vec<Value> {
        let seen = wait_until(|| self.reads().len() >= count, WAIT_TIMEOUT).await;
        assert!(
            seen,
            "expected {count} read pushes, saw {}",
            self.reads().len()
        );
        self.reads()
    }
}

fn tokens(messages: &[Value]) -> Vec<&str> {
    messages
        .iter()
        .filter_map(|m| m["token"].as_str())
        .collect()
}

#[tokio::test]
async fn a_read_reaches_the_other_device_and_never_the_one_that_read() {
    let world = world().await;
    let seq = world.alice_says("hello").await;

    world.read(&world.desktop, seq).await;

    let reads = world.wait_for_reads(1).await;
    tokio::time::sleep(WINDOW * 2).await;
    assert_eq!(tokens(&world.reads()), vec!["phone-fcm"]);
    assert_eq!(reads.len(), 1);
}

#[tokio::test]
async fn the_read_envelope_names_the_channel_and_carries_no_content() {
    let world = world().await;
    let seq = world.alice_says("a secret").await;

    world.read(&world.desktop, seq).await;

    let read = world.wait_for_reads(1).await.remove(0);
    let sealed = BASE64.decode(read["payload"].as_str().unwrap()).unwrap();
    let envelope: Value =
        serde_json::from_slice(&world.phone_secret.unseal(&sealed).unwrap()).unwrap();
    assert_eq!(envelope["kind"], "read");
    assert_eq!(envelope["channel_id"], world.channel_id);
    let mut keys: Vec<_> = envelope.as_object().unwrap().keys().cloned().collect();
    keys.sort();
    assert_eq!(keys, ["channel_id", "domain", "kind", "sent_at", "version"]);
    assert!(!read.to_string().contains("a secret"));
}

#[tokio::test]
async fn a_burst_of_reads_in_one_channel_is_one_push() {
    let world = world().await;
    let first = world.alice_says("one").await;
    world.read(&world.desktop, first).await;
    let second = world.alice_says("two").await;
    world.read(&world.desktop, second).await;
    let third = world.alice_says("three").await;
    world.read(&world.desktop, third).await;

    world.wait_for_reads(1).await;
    tokio::time::sleep(WINDOW * 3).await;

    assert_eq!(world.reads().len(), 1);
}

#[tokio::test]
async fn a_read_that_moves_nothing_pushes_nothing() {
    let world = world().await;
    let seq = world.alice_says("hello").await;
    world.read(&world.desktop, seq).await;
    world.wait_for_reads(1).await;
    tokio::time::sleep(WINDOW * 2).await;

    world.read(&world.desktop, seq).await;
    tokio::time::sleep(WINDOW * 3).await;

    assert_eq!(world.reads().len(), 1);
}

#[tokio::test]
async fn the_phone_reading_clears_the_desktop_instead() {
    let world = world().await;
    let seq = world.alice_says("hello").await;

    world.read(&world.phone, seq).await;

    world.wait_for_reads(1).await;
    assert_eq!(tokens(&world.reads()), vec!["desktop-fcm"]);
}

#[tokio::test]
async fn marking_a_whole_channel_read_in_bulk_pushes_too() {
    let world = world().await;
    world.alice_says("hello").await;

    let response = world
        .app
        .clone()
        .oneshot(request(
            "POST",
            "/read-states/read",
            Some(&world.desktop),
            Some(json!({ "channel_ids": [world.channel_id] })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::OK);

    world.wait_for_reads(1).await;
    assert_eq!(tokens(&world.reads()), vec!["phone-fcm"]);
}
