// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A message with no text of its own still says something on a lock screen.
//!
//! Bots post embeds with empty `content`; the iOS extension refuses an empty
//! preview body and leaves the relay's generic "New message", which is what
//! the owner saw for every bot post. The reader chose "everything" for the
//! channel, since a bot post only wakes someone who did.

mod push_envelope_harness;
mod support;

use push_envelope_harness::*;
use serde_json::json;
use slimm_server::notifications::NotificationPreference;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

/// The 8-byte PNG magic number is all the upload route sniffs.
const PNG: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

async fn upload(world: &World, token: &str) -> String {
    let response = world
        .app
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .method("POST")
                .uri("/attachments?filename=poster.png")
                .header("authorization", format!("Bearer {token}"))
                .body(axum::body::Body::from(PNG.to_vec()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::CREATED);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice::<serde_json::Value>(&bytes).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// What the Jellyfin bot posts for a new library item: no text, a poster
/// image, and an embed naming the item.
#[tokio::test]
async fn a_poster_and_embed_post_with_no_text_previews_the_embed() {
    let world = world().await;
    let reader = account(&world.store, "reader", "Reader").await;
    let secret = register_push(&world.app, &reader, "reader-token", true).await;
    let reader_id = world
        .store
        .live_user_id_by_username("reader")
        .await
        .unwrap()
        .unwrap();
    world
        .store
        .set_channel_notification_preference(
            reader_id,
            world.channel_id,
            NotificationPreference::Everything,
        )
        .await
        .unwrap();
    let owner = world.store.create_user("owner", "Owner").await.unwrap();
    let bot = world
        .store
        .create_bot(
            "radarr",
            "Radarr",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            owner.id,
        )
        .await
        .expect("bot");
    let poster = upload(&world, &bot.token).await;

    let response = world
        .app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages", world.channel_id),
            Some(&bot.token),
            Some(json!({
                "id": uuid::Uuid::now_v7().to_string(),
                "content": "",
                "attachment_ids": [poster],
                "embeds": [{ "title": "Dune: Part Two downloaded", "description": "2160p" }],
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::OK);

    let body = wait_for_capture(&world.captured).await;
    let envelope = unseal(entry_for(&body, "reader-token"), &secret);
    assert_eq!(envelope["sender"], "Radarr");
    assert_eq!(envelope["body"], "Dune: Part Two downloaded");
}
