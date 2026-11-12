// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Storage is content addressed, but the display filename belongs to the
//! message that carries the bytes, not to whoever uploaded them first.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::attachments::fixtures::*;

/// Uploads `bytes` as `name`, sends it in `channel`, returns the message id.
async fn send_as(app: &Router, token: &str, channel: &str, name: &str, bytes: Vec<u8>) -> String {
    let uploaded = upload(app, token, name, bytes).await;
    let message_id = Uuid::now_v7().to_string();
    let sent = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{channel}/messages"),
            token,
            json!({
                "id": message_id,
                "content": "x",
                "attachment_ids": [uploaded["id"]],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
    let echoed = json_body(sent).await;
    assert_eq!(echoed["attachments"][0]["filename"], name, "the send echo");
    message_id
}

async fn filename_in_list(app: &Router, token: &str, channel: &str, message_id: &str) -> String {
    let response = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/channels/{channel}/messages"),
            token,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let list = json_body(response).await;
    let messages: &Vec<Value> = list
        .as_array()
        .unwrap_or_else(|| list["messages"].as_array().unwrap());
    let message = messages.iter().find(|m| m["id"] == message_id).unwrap();
    message["attachments"][0]["filename"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn identical_bytes_keep_each_senders_own_filename() {
    let (store, _guard) = new_store().await;
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
    let (bob, _) = register(&store, "bob").await;

    let first = send_as(&app, &alice, &channel, "img1.png", png(4)).await;
    let second = send_as(&app, &bob, &channel, "pasted-image.png", png(4)).await;
    let third = send_as(&app, &alice, &channel, "renamed.png", png(4)).await;

    assert_eq!(
        filename_in_list(&app, &bob, &channel, &first).await,
        "img1.png"
    );
    assert_eq!(
        filename_in_list(&app, &alice, &channel, &second).await,
        "pasted-image.png"
    );
    assert_eq!(
        filename_in_list(&app, &bob, &channel, &third).await,
        "renamed.png"
    );
}
