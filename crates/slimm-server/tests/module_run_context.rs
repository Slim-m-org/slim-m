// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module run is told the channel it was started from, and the voice
//! channel only when the host confirmed the member is in it.

use axum::body::Body;
use axum::http::Request;
use serde_json::{Value, json};
use slimm_server::ids::ChannelId;

mod support;
use support::module_world::{Install, World, world};
use support::wasm_fixtures::echo_request_wasm;

async fn echoing_world(name: &str) -> World {
    let w = world(name).await;
    w.install(Install {
        id: "echo",
        wasm: echo_request_wasm(),
        declared: &[],
        approved_host: &[],
    })
    .await;
    w
}

async fn run_with(w: &World, channel: Option<ChannelId>, voice: Option<ChannelId>) -> String {
    let mut body = json!({ "input": "go" });
    if let Some(channel) = channel {
        body["channel_id"] = json!(channel.to_string());
    }
    if let Some(voice) = voice {
        body["voice_channel_id"] = json!(voice.to_string());
    }
    let request = Request::builder()
        .method("POST")
        .uri("/modules/echo/commands/run")
        .header("authorization", format!("Bearer {}", w.token))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let answer: Value = w.send(request).await;
    answer["output"].as_str().expect("an output").to_owned()
}

#[tokio::test]
async fn a_command_is_told_the_channel_it_ran_in() {
    let w = echoing_world("slimm-runctx-channel").await;
    let channel = w.store.create_channel("games", "text").await.unwrap();
    let seen = run_with(&w, Some(channel.id), None).await;
    assert!(
        seen.contains(&format!("'context':{{'channel_id':'{}'}}", channel.id)),
        "{seen}"
    );
    assert!(!seen.contains("voice_channel_id"), "{seen}");
}

#[tokio::test]
async fn a_run_from_nowhere_carries_no_context() {
    let w = echoing_world("slimm-runctx-none").await;
    let seen = run_with(&w, None, None).await;
    assert!(!seen.contains("context"), "{seen}");
}

#[tokio::test]
async fn a_voice_channel_the_member_is_not_in_is_not_passed_on() {
    let w = echoing_world("slimm-runctx-voice-claim").await;
    let text = w.store.create_channel("games", "text").await.unwrap();
    let voice = w.store.create_channel("lounge", "voice").await.unwrap();
    let seen = run_with(&w, Some(text.id), Some(voice.id)).await;
    assert!(!seen.contains("voice_channel_id"), "{seen}");
}

#[tokio::test]
async fn a_voice_channel_the_member_is_in_is_passed_on() {
    let w = echoing_world("slimm-runctx-voice").await;
    let text = w.store.create_channel("games", "text").await.unwrap();
    let voice = w.store.create_channel("lounge", "voice").await.unwrap();
    w.state
        .voice
        .record_heartbeat_reporting_new(w.user.id, voice.id);
    let seen = run_with(&w, Some(text.id), Some(voice.id)).await;
    assert!(
        seen.contains(&format!("'voice_channel_id':'{}'", voice.id)),
        "{seen}"
    );
}
