// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A lock-screen preview never shows what the transcript hides, and names what a message is
//! when it has no text of its own.

use crate::push_envelope_harness;
use push_envelope_harness::*;
use serde_json::{Value, json};
use slimm_server::notifications::NotificationPreference;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

/// A reader who wants previews for every message in the channel.
async fn reader(world: &World) -> crypto_box::SecretKey {
    let token = account(&world.store, "reader", "Reader").await;
    let secret = register_push(&world.app, &token, "reader-token", true).await;
    let id = world
        .store
        .live_user_id_by_username("reader")
        .await
        .unwrap()
        .unwrap();
    world
        .store
        .set_channel_notification_preference(
            id,
            world.channel_id,
            NotificationPreference::Everything,
        )
        .await
        .unwrap();
    secret
}

async fn preview_body(world: &World, secret: &crypto_box::SecretKey) -> Value {
    let body = wait_for_capture(&world.captured).await;
    unseal(entry_for(&body, "reader-token"), secret)["body"].clone()
}

async fn post(world: &World, path: &str, body: Value) {
    post_as(world, &world.author_token, path, body).await;
}

async fn post_as(world: &World, token: &str, path: &str, body: Value) {
    let response = world
        .app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}{path}", world.channel_id),
            Some(token),
            Some(body),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::OK);
}

#[tokio::test]
async fn spoiler_text_is_masked_in_the_preview() {
    let world = world().await;
    let secret = reader(&world).await;
    send(&world, "the butler ||did it|| honestly").await;
    assert_eq!(
        preview_body(&world, &secret).await,
        "the butler [spoiler] honestly"
    );
}

#[tokio::test]
async fn a_spoiler_file_name_is_not_in_the_preview() {
    let world = world().await;
    let secret = reader(&world).await;
    let owner = world.store.create_user("owner", "Owner").await.unwrap();
    let bot = world
        .store
        .create_bot(
            "filer",
            "Filer",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            owner.id,
        )
        .await
        .expect("bot");
    let uploaded = world
        .app
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .method("POST")
                .uri("/attachments?filename=the-ending.pdf")
                .header("authorization", format!("Bearer {}", bot.token))
                .body(axum::body::Body::from(b"%PDF-1.4 the end".to_vec()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(uploaded.status(), axum::http::StatusCode::CREATED);
    let bytes = axum::body::to_bytes(uploaded.into_body(), usize::MAX)
        .await
        .unwrap();
    let id = serde_json::from_slice::<Value>(&bytes).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    post_as(
        &world,
        &bot.token,
        "/messages",
        json!({
            "id": uuid::Uuid::now_v7().to_string(),
            "content": "",
            "attachment_ids": [id],
            "spoiler_attachment_ids": [id],
        }),
    )
    .await;
    let body = preview_body(&world, &secret).await;
    assert!(
        !body.as_str().unwrap().contains("the-ending"),
        "preview was {body}"
    );
}

#[tokio::test]
async fn a_poll_without_a_caption_previews_its_question() {
    let world = world().await;
    let secret = reader(&world).await;
    post(
        &world,
        "/messages/polls",
        json!({
            "id": uuid::Uuid::now_v7().to_string(),
            "question": "lunch at noon?",
            "options": ["yes", "no"],
        }),
    )
    .await;
    assert_eq!(preview_body(&world, &secret).await, "lunch at noon?");
}
