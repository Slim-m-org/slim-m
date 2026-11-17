// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A join that published nothing is announced to the call at once: LiveKit batches such a
//! participant for up to 3 s, so the server clears an unused attribute, which it sends at once.

use std::time::Duration;

use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::store::Store;
use slimm_server::voice::{ANNOUNCE_ATTRIBUTE, VoiceService};
use tower::ServiceExt;

use crate::support;
use support::fake_sfu::{RecordingRoomService, spawn_sfu};
use support::livekit_webhook::webhook_request;

const API_KEY: &str = "APItestkey";
const API_SECRET: &str = "a-test-secret-of-at-least-32-characters";

struct World {
    app: axum::Router,
    recorder: RecordingRoomService,
    channel: ChannelId,
    alice: UserId,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let recorder = RecordingRoomService::default();
    let sfu_url = spawn_sfu(recorder.clone()).await;
    let (store, guard): (Store, _) = support::new_store("slimm-voice-join-announce-test").await;
    let alice = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let channel = store.create_channel("lounge", "voice").await.unwrap();
    let app = support::app::builder(store)
        .voice(VoiceService::for_test(&sfu_url, API_KEY, API_SECRET))
        .router();
    World {
        app,
        recorder,
        channel: channel.id,
        alice: alice.id,
        _guard: guard,
    }
}

impl World {
    async fn join(&self, sid: &str, is_publisher: Option<bool>) {
        let mut participant = json!({ "identity": self.alice.to_string(), "sid": sid });
        if let Some(published) = is_publisher {
            participant["is_publisher"] = json!(published);
        }
        let body = json!({
            "event": "participant_joined",
            "room": { "name": format!("channel-{}", self.channel) },
            "participant": participant,
        });
        let response = self
            .app
            .clone()
            .oneshot(webhook_request(body, API_KEY, API_SECRET))
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::NO_CONTENT);
    }

    fn announces(&self) -> Vec<Value> {
        self.recorder
            .updates
            .lock()
            .unwrap()
            .iter()
            .filter(|u| u["attributes"].get(ANNOUNCE_ATTRIBUTE).is_some())
            .cloned()
            .collect()
    }

    /// The announce is detached from the delivery, so it is waited for rather than read at once.
    async fn announces_after_settling(&self, wanted: usize) -> Vec<Value> {
        for _ in 0..100 {
            if self.announces().len() >= wanted {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
        self.announces()
    }
}

#[tokio::test]
async fn a_join_that_published_nothing_is_announced_at_once() {
    let world = world().await;

    world.join("PA_one", None).await;

    let announces = world.announces_after_settling(1).await;
    assert_eq!(announces.len(), 1, "{announces:?}");
    assert_eq!(announces[0]["room"], format!("channel-{}", world.channel));
    assert_eq!(announces[0]["identity"], world.alice.to_string());
    assert_eq!(announces[0]["attributes"][ANNOUNCE_ATTRIBUTE], "");
}

#[tokio::test]
async fn a_join_that_already_publishes_is_left_to_the_sfu() {
    let world = world().await;

    world.join("PA_one", Some(true)).await;

    assert!(world.announces_after_settling(1).await.is_empty());
}

#[tokio::test]
async fn a_repeated_delivery_of_one_join_announces_it_once() {
    let world = world().await;

    world.join("PA_one", Some(false)).await;
    world.join("PA_one", Some(false)).await;

    assert_eq!(world.announces_after_settling(2).await.len(), 1);
}
