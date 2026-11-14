// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A voice message is an audio upload carrying its length and waveform: they
//! come back on the upload, and on every read of a message carrying it.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::attachments::fixtures::*;

fn ogg(tail: u8) -> Vec<u8> {
    let mut bytes = b"OggS".to_vec();
    bytes.extend([0, tail, 1, 2, 3]);
    bytes
}

fn waveform_hex() -> String {
    (0..64).map(|n| format!("{n:02x}")).collect()
}

async fn post(app: &Router, token: &str, query: &str, bytes: Vec<u8>) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request_bytes(
            "POST",
            &format!("/attachments?filename=voice.ogg&{query}"),
            token,
            bytes,
        ))
        .await
        .unwrap();
    let status = response.status();
    (status, json_body(response).await)
}

async fn setup() -> (Router, String, String, crate::support::TestDbGuard) {
    let (store, guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let channel = store
        .create_channel("general", "text")
        .await
        .unwrap()
        .id
        .to_string();
    let app = app(store.clone());
    let (alice, _) = register(&store, "alice").await;
    (app, alice, channel, guard)
}

#[tokio::test]
async fn a_voice_upload_returns_its_length_and_waveform_and_keeps_them_on_the_message() {
    let (app, alice, channel, _guard) = setup().await;
    let query = format!("voice=true&duration_ms=4200&waveform={}", waveform_hex());
    let (status, uploaded) = post(&app, &alice, &query, ogg(1)).await;
    assert_eq!(status, StatusCode::CREATED, "{uploaded}");
    assert_eq!(uploaded["voice"], true);
    assert_eq!(uploaded["duration_ms"], 4200);
    assert_eq!(uploaded["waveform"].as_array().unwrap().len(), 64);
    assert_eq!(uploaded["waveform"][5], 5);

    let message_id = Uuid::now_v7().to_string();
    let response = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{channel}/messages"),
            &alice,
            json!({ "id": message_id, "content": "", "attachment_ids": [uploaded["id"]] }),
        ))
        .await
        .unwrap();
    let echoed = json_body(response).await;
    assert_eq!(echoed["attachments"][0]["voice"], true, "{echoed}");

    let listed = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/channels/{channel}/messages"),
            &alice,
        ))
        .await
        .unwrap();
    let list = json_body(listed).await;
    let messages = list
        .as_array()
        .cloned()
        .unwrap_or_else(|| list["messages"].as_array().unwrap().clone());
    let reread = messages.iter().find(|m| m["id"] == message_id).unwrap();
    assert_eq!(reread["attachments"][0]["duration_ms"], 4200);
    assert_eq!(reread["attachments"][0]["waveform"][63], 63);
}

#[tokio::test]
async fn an_ordinary_audio_upload_is_not_a_voice_message() {
    let (app, alice, _channel, _guard) = setup().await;
    let (status, uploaded) = post(&app, &alice, "", ogg(2)).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(uploaded.get("voice"), None);
    assert_eq!(uploaded.get("waveform"), None);
}

#[tokio::test]
async fn a_malformed_voice_upload_is_a_bad_request() {
    let (app, alice, _channel, _guard) = setup().await;
    for query in [
        "voice=true".to_owned(),
        format!("voice=true&duration_ms=0&waveform={}", waveform_hex()),
        "voice=true&duration_ms=1000&waveform=0a0b".to_owned(),
    ] {
        let (status, _) = post(&app, &alice, &query, ogg(3)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{query}");
    }
}

#[tokio::test]
async fn a_voice_flag_on_something_that_is_not_audio_is_refused() {
    let (app, alice, _channel, _guard) = setup().await;
    let query = format!("voice=true&duration_ms=1000&waveform={}", waveform_hex());
    let (status, _) = post(&app, &alice, &query, png(4)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}
