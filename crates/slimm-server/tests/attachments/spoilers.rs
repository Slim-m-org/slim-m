// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A spoiler belongs to the message that hides the bytes, not to the bytes:
//! the same image can be a spoiler on one message and plain on another.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::fixtures::*;

async fn send(app: &Router, token: &str, channel: &str, body: Value) -> (StatusCode, Value) {
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
    let status = response.status();
    (status, json_body(response).await)
}

async fn listed(app: &Router, token: &str, channel: &str, message_id: &str) -> Value {
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
    messages
        .into_iter()
        .find(|m| m["id"] == message_id)
        .unwrap()
}

#[tokio::test]
async fn a_spoiler_is_per_message_and_survives_a_reread() {
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
    let first = upload(&app, &alice, "plot.png", png(4)).await["id"].clone();
    let second = upload(&app, &alice, "ending.png", png(5)).await["id"].clone();

    let hidden_id = Uuid::now_v7().to_string();
    let (status, echoed) = send(
        &app,
        &alice,
        &channel,
        json!({
            "id": hidden_id,
            "content": "",
            "attachment_ids": [first, second],
            "spoiler_attachment_ids": [second],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{echoed}");
    assert_eq!(
        echoed["attachments"][0].get("spoiler"),
        None,
        "false is omitted"
    );
    assert_eq!(echoed["attachments"][1]["spoiler"], true);

    let plain_id = Uuid::now_v7().to_string();
    let (status, _) = send(
        &app,
        &alice,
        &channel,
        json!({ "id": plain_id, "content": "", "attachment_ids": [second] }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let hidden = listed(&app, &alice, &channel, &hidden_id).await;
    assert_eq!(hidden["attachments"][1]["spoiler"], true);
    let plain = listed(&app, &alice, &channel, &plain_id).await;
    assert_eq!(
        plain["attachments"][0].get("spoiler"),
        None,
        "the same bytes on another message are not hidden"
    );
}

#[tokio::test]
async fn a_spoiler_must_be_one_of_the_message_attachments() {
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
    let attached = upload(&app, &alice, "a.png", png(4)).await["id"].clone();
    let other = upload(&app, &alice, "b.png", png(5)).await["id"].clone();

    let (status, _) = send(
        &app,
        &alice,
        &channel,
        json!({
            "id": Uuid::now_v7().to_string(),
            "content": "",
            "attachment_ids": [attached],
            "spoiler_attachment_ids": [other],
        }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}
