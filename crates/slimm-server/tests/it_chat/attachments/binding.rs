// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An attachment's relationship to the message carrying it: what a send has
//! to carry to be a message at all, and what happens to the file when that
//! message is deleted.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::attachments::fixtures::*;

#[tokio::test]
async fn deleting_a_message_releases_its_attachment() {
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
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let uploaded = upload(&app, &token, "gone-soon.png", png(4)).await;
    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();
    let message_id = Uuid::now_v7().to_string();
    let sent = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            &token,
            json!({
                "id": message_id,
                "content": "temporary",
                "attachment_ids": [attachment_id.clone()],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);

    let fetch_uri = format!("/attachments/{attachment_id}");
    let before = app
        .clone()
        .oneshot(request_plain("GET", &fetch_uri, &token))
        .await
        .unwrap();
    assert_eq!(before.status(), StatusCode::OK, "sanity: it exists first");

    let deleted = app
        .clone()
        .oneshot(request_plain(
            "DELETE",
            &format!("/channels/{}/messages/{message_id}", channel.id),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let after = app
        .clone()
        .oneshot(request_plain("GET", &fetch_uri, &token))
        .await
        .unwrap();
    assert_eq!(
        after.status(),
        StatusCode::NOT_FOUND,
        "a deleted message's attachment must no longer be fetchable"
    );
}

/// The composer's send button was dead with a photo staged and no text typed,
/// and enabling it would have posted a request the server refused: sending
/// validated content before it knew an attachment was riding along. A file is
/// a message on its own, and a send carrying neither text nor file still is
/// not.
#[tokio::test]
async fn a_send_carrying_an_attachment_needs_no_text() {
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
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let uploaded = upload(&app, &token, "holiday.png", png(16)).await;
    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();
    let uri = format!("/channels/{}/messages", channel.id);

    let sent = app
        .clone()
        .oneshot(request_json(
            "POST",
            &uri,
            &token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "",
                "attachment_ids": [attachment_id],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(
        sent.status(),
        StatusCode::OK,
        "a photo with no caption is a message"
    );
    let sent = json_body(sent).await;
    assert_eq!(sent["content"].as_str().unwrap(), "");
    assert_eq!(sent["attachments"].as_array().unwrap().len(), 1);

    let empty = app
        .clone()
        .oneshot(request_json(
            "POST",
            &uri,
            &token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "   ",
                "attachment_ids": [],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(
        empty.status(),
        StatusCode::BAD_REQUEST,
        "carrying nothing at all is still refused"
    );
}

/// A repeated id in `attachment_ids` is a 400 naming the problem, not the 500
/// the link table's (message_id, sha256) primary key otherwise turns it into.
#[tokio::test]
async fn a_duplicated_attachment_id_is_refused_as_bad_request() {
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
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let uploaded = upload(&app, &token, "twice.png", png(4)).await;
    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();

    let sent = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            &token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "the same file twice",
                "attachment_ids": [attachment_id.clone(), attachment_id],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::BAD_REQUEST);
}
