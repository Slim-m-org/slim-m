// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A voice message belongs to the message carrying it, not to the bytes: the
//! same file is one member's voice message and another's plain share in
//! either order, a forward keeps what it passes on, and a transcript shows
//! only where the link is a voice message.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::{Event, Hub, MessageEvent};
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::voice_transcripts::VoiceTranscriber;
use tower::ServiceExt;
use uuid::Uuid;

use crate::attachments::fixtures::*;
use crate::attachments::text_search::world;
use crate::attachments::voice_transcripts::Fake;

fn meme() -> Vec<u8> {
    b"ID3\x03\x00\x00\x00meme".to_vec()
}

fn voice_query(duration_ms: i64) -> String {
    let waveform: String = (0..64).map(|n| format!("{n:02x}")).collect();
    format!("voice=true&duration_ms={duration_ms}&waveform={waveform}")
}

async fn upload_as(app: &Router, token: &str, query: &str, bytes: Vec<u8>) -> Value {
    let response = app
        .clone()
        .oneshot(request_bytes(
            "POST",
            &format!("/attachments?filename=meme.mp3&{query}"),
            token,
            bytes,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    json_body(response).await
}

async fn send_to(app: &Router, channel: &str, token: &str, body: Value) -> String {
    let id = Uuid::now_v7().to_string();
    let mut body = body;
    body["id"] = json!(id);
    body["content"] = json!("");
    let response = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{channel}/messages"),
            token,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    id
}

async fn attachments_of(app: &Router, channel: &str, token: &str, message_id: &str) -> Value {
    let response = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/channels/{channel}/messages"),
            token,
        ))
        .await
        .unwrap();
    let list = json_body(response).await;
    let messages = list
        .as_array()
        .cloned()
        .unwrap_or_else(|| list["messages"].as_array().unwrap().clone());
    let message = messages.iter().find(|m| m["id"] == message_id).unwrap();
    message["attachments"].clone()
}

async fn first_attachment(app: &Router, channel: &str, token: &str, message_id: &str) -> Value {
    attachments_of(app, channel, token, message_id).await[0].clone()
}

struct Members {
    app: Router,
    alice: String,
    bob: String,
    carol: String,
    channel: String,
    _guard: crate::support::TestDbGuard,
}

async fn members() -> Members {
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
    let (alice, _) = register(&store, "alice").await;
    let (bob, _) = register(&store, "bob").await;
    let (carol, _) = register(&store, "carol").await;
    Members {
        app: app(store),
        alice,
        bob,
        carol,
        channel,
        _guard: guard,
    }
}

impl Members {
    async fn share(&self, token: &str, query: &str) -> (String, Value) {
        let uploaded = upload_as(&self.app, token, query, meme()).await;
        let body = json!({ "attachment_ids": [uploaded["id"]] });
        (
            send_to(&self.app, &self.channel, token, body).await,
            uploaded,
        )
    }

    async fn forward(&self, token: &str, message_id: &str, attachment: &Value) -> String {
        let body = json!({ "attachment_ids": [attachment], "forwarded_from_id": message_id });
        send_to(&self.app, &self.channel, token, body).await
    }

    async fn shown(&self, message_id: &str) -> Value {
        first_attachment(&self.app, &self.channel, &self.carol, message_id).await
    }
}

#[tokio::test]
async fn a_plain_share_of_bytes_someone_sent_as_a_voice_message_stays_a_plain_file() {
    let m = members().await;
    let (bobs, _) = m.share(&m.bob, &voice_query(4200)).await;
    let (alices, _) = m.share(&m.alice, "").await;
    assert_eq!(m.shown(&alices).await.get("voice"), None);
    assert_eq!(m.shown(&bobs).await["duration_ms"], 4200);
}

#[tokio::test]
async fn a_voice_message_of_bytes_someone_shared_as_a_file_is_still_a_voice_message() {
    let m = members().await;
    let (alices, _) = m.share(&m.alice, "").await;
    let (bobs, uploaded) = m.share(&m.bob, &voice_query(4200)).await;
    assert_eq!(uploaded["voice"], true, "{uploaded}");
    assert_eq!(m.shown(&bobs).await["duration_ms"], 4200);
    assert_eq!(m.shown(&alices).await.get("voice"), None);
}

#[tokio::test]
async fn a_forward_keeps_what_the_original_was() {
    let m = members().await;
    let (bobs, uploaded) = m.share(&m.bob, &voice_query(4200)).await;
    let (alices, _) = m.share(&m.alice, "").await;

    let carols = m.forward(&m.carol, &bobs, &uploaded["id"]).await;
    assert_eq!(m.shown(&carols).await["duration_ms"], 4200);
    assert_eq!(m.shown(&carols).await["waveform"][7], 7);
    let again = m.forward(&m.alice, &carols, &uploaded["id"]).await;
    assert_eq!(
        m.shown(&again).await["voice"],
        true,
        "a forward of a forward"
    );

    let plain = m.forward(&m.bob, &alices, &uploaded["id"]).await;
    assert_eq!(
        m.shown(&plain).await.get("voice"),
        None,
        "bob's own voice upload does not relabel alice's file he passes on"
    );
}

#[tokio::test]
async fn a_forward_of_a_forward_copies_what_the_forward_it_names_carried() {
    let m = members().await;
    let (bobs, song) = m.share(&m.bob, "").await;
    let clip = upload_as(
        &m.app,
        &m.carol,
        &voice_query(1500),
        b"ID3\x03clip".to_vec(),
    )
    .await;
    let both = json!([song["id"], clip["id"]]);
    let body = json!({ "attachment_ids": both, "forwarded_from_id": bobs });
    let carols = send_to(&m.app, &m.channel, &m.carol, body).await;
    let body = json!({ "attachment_ids": both, "forwarded_from_id": carols });
    let alices = send_to(&m.app, &m.channel, &m.alice, body).await;
    let shown = attachments_of(&m.app, &m.channel, &m.alice, &alices).await;
    assert_eq!(shown[0].get("voice"), None, "{shown}");
    assert_eq!(
        shown[1]["duration_ms"], 1500,
        "carol's own clip stays hers: {shown}"
    );
}

#[tokio::test]
async fn sending_someone_elses_voice_clip_without_forwarding_it_is_a_plain_file() {
    let m = members().await;
    let (_, uploaded) = m.share(&m.bob, &voice_query(4200)).await;
    let body = json!({ "attachment_ids": [uploaded["id"]] });
    let carols = send_to(&m.app, &m.channel, &m.carol, body).await;
    assert_eq!(m.shown(&carols).await.get("voice"), None);
}

#[tokio::test]
async fn an_uploaders_latest_upload_decides_what_their_next_send_carries() {
    let m = members().await;
    upload_as(&m.app, &m.alice, &voice_query(4200), meme()).await;
    let (shorter, uploaded) = m.share(&m.alice, &voice_query(1000)).await;
    assert_eq!(uploaded["duration_ms"], 1000, "{uploaded}");
    assert_eq!(m.shown(&shorter).await["duration_ms"], 1000);

    let (plain, uploaded) = m.share(&m.alice, "").await;
    assert_eq!(uploaded.get("voice"), None, "{uploaded}");
    assert_eq!(m.shown(&plain).await.get("voice"), None);
    assert_eq!(
        m.shown(&shorter).await["duration_ms"],
        1000,
        "a message already sent keeps what it was sent as"
    );
}

#[tokio::test]
async fn a_transcript_shows_only_on_the_voice_message_not_on_a_plain_share_of_the_bytes() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    let (bob, _) = register(&world.store, "bob").await;
    let uploaded = upload_as(&world.app, &world.token, &voice_query(3000), meme()).await;
    let body = json!({ "attachment_ids": [uploaded["id"]] });
    let voice = send_to(&world.app, &world.channel, &world.token, body.clone()).await;
    upload_as(&world.app, &bob, "", meme()).await;
    let plain = send_to(&world.app, &world.channel, &bob, body).await;

    let hub = Hub::new();
    let mut events = hub.subscribe_ephemeral();
    let engine = Fake::saying("meet me at the lighthouse");
    VoiceTranscriber::with_backoff(std::time::Duration::from_millis(1))
        .run_pass(&world.store, &world.media, &hub, &engine)
        .await;

    let heard = first_attachment(&world.app, &world.channel, &world.token, &voice).await;
    assert_eq!(heard["transcript"]["status"], "ready", "{heard}");
    let file = first_attachment(&world.app, &world.channel, &world.token, &plain).await;
    assert_eq!(file.get("transcript"), None, "{file}");
    assert_eq!(file.get("voice"), None, "{file}");
    let found: Vec<Value> = world
        .search("lighthouse")
        .await
        .into_iter()
        .map(|m| m["id"].clone())
        .collect();
    assert_eq!(found, [json!(voice)], "search finds only the voice message");
    let plain_id = [MessageId(Uuid::parse_str(&plain).unwrap())];
    let matched = world
        .store
        .attachments_matching_text(&plain_id, "lighthouse")
        .await
        .unwrap();
    assert!(matched.is_empty(), "no found-in label on the plain file");
    let mut announced = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let Event::Message(MessageEvent::VoiceTranscript { message_id, .. }) = event {
            announced.push(message_id.to_string());
        }
    }
    assert_eq!(
        announced,
        [voice.clone(), voice],
        "pending then ready, only to the voice message"
    );
}
