// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What deleting an original does to copies that carry a file or a pin.

use super::fixtures::*;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::{Event, Hub, MessageEvent};
use slimm_server::ids::{ChannelId, MessageId};
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

fn png(tag: u8) -> Vec<u8> {
    let mut bytes = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    bytes.extend([tag; 8]);
    bytes
}

async fn upload(app: &axum::Router, token: &str, bytes: Vec<u8>) -> String {
    let response = app
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .method("POST")
                .uri("/attachments?filename=copy.png")
                .header("authorization", format!("Bearer {token}"))
                .body(axum::body::Body::from(bytes))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    json_body(response).await["id"].as_str().unwrap().to_owned()
}

async fn delete_message(app: &axum::Router, channel: &str, message: &Value, token: &str) {
    let uri = format!(
        "/channels/{channel}/messages/{}",
        message["id"].as_str().unwrap()
    );
    let response = app
        .clone()
        .oneshot(request("DELETE", &uri, token, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}

async fn deployment_with_uploads(store: &Store) -> (ChannelId, String) {
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
    let channel = store.create_channel("general", "text").await.unwrap();
    (channel.id, register(store, "alice", "Alice").await)
}

#[tokio::test]
async fn deleting_the_original_detaches_a_copy_with_only_an_attachment() {
    let (store, _guard) = new_store().await;
    let (channel, token) = deployment_with_uploads(&store).await;
    let media = Media::for_tests();
    let app = app_with_media(store.clone(), Hub::new(), media.clone());
    let general = channel.to_string();
    let other = store
        .create_channel("other", "text")
        .await
        .unwrap()
        .id
        .to_string();
    let original = send(&app, &general, &token, "to be deleted").await;
    let file = upload(&app, &token, png(1)).await;
    let mut body = forward_body("", &original);
    body["attachment_ids"] = json!([file]);
    let copy = json_body(post(&app, &other, &token, body).await).await;

    delete_message(&app, &general, &original, &token).await;

    let page = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{other}/messages"),
                &token,
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let kept = page
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == copy["id"])
        .expect("a copy with its own attachment stays");
    assert_eq!(kept["forwarded"]["removed"], true);
    let fetched = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/attachments/{file}"),
            &token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(fetched.status(), StatusCode::OK);
    assert!(media.read_attachment(&file).await.is_ok(), "file kept");
}

#[tokio::test]
async fn deleting_the_original_removes_a_pinned_copy_and_unpins_it() {
    let (store, _guard) = new_store().await;
    let (channel, token) = open_deployment(&store).await;
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());
    let general = channel.to_string();
    let other = store
        .create_channel("other", "text")
        .await
        .unwrap()
        .id
        .to_string();
    let original = send(&app, &general, &token, "to be deleted").await;
    let copy = json_body(post(&app, &other, &token, forward_body("", &original)).await).await;
    let pin = format!(
        "/channels/{other}/messages/{}/pin",
        copy["id"].as_str().unwrap()
    );
    let pinned = app
        .clone()
        .oneshot(request("PUT", &pin, &token, None))
        .await
        .unwrap();
    assert_eq!(pinned.status(), StatusCode::NO_CONTENT);

    let mut rx = hub.subscribe();
    delete_message(&app, &general, &original, &token).await;

    let copy_id = MessageId(Uuid::parse_str(copy["id"].as_str().unwrap()).unwrap());
    let (mut deleted, mut unpinned) = (false, false);
    while let Ok(event) = rx.try_recv() {
        match event {
            Event::Message(MessageEvent::Deleted { message_id, .. }) if message_id == copy_id => {
                deleted = true
            }
            Event::Message(MessageEvent::Unpinned { message_id, .. }) if message_id == copy_id => {
                unpinned = true
            }
            _ => {}
        }
    }
    assert!(deleted, "the copy's channel hears a delete");
    assert!(unpinned, "a pinned copy is unpinned on the way out");
}
