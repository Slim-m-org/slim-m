// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Content addressing shares one `attachments` row between uploaders, so
//! deleting one member's message must not pull bytes another member staged.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::fixtures::*;

#[tokio::test]
async fn deleting_a_message_keeps_bytes_another_member_staged() {
    let (store, _guard) = new_store().await;
    let everyone = Permissions::VIEW_CHANNEL
        .union(Permissions::SEND_MESSAGES)
        .union(Permissions::ATTACH_FILES);
    store.create_role("everyone", everyone, true).await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (bob, _) = register(&store, "bob").await;
    let (alice, _) = register(&store, "alice").await;

    let staged = upload(&app, &bob, "shared.png", png(7)).await;
    let attachment_id = staged["id"].as_str().unwrap().to_owned();
    let also = upload(&app, &alice, "shared.png", png(7)).await;
    assert_eq!(
        also["id"], staged["id"],
        "sanity: identical bytes share an id"
    );

    let message_id = Uuid::now_v7().to_string();
    let sent = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            &alice,
            json!({"id": message_id, "content": "x", "attachment_ids": [attachment_id.clone()]}),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
    let deleted = app
        .clone()
        .oneshot(request_plain(
            "DELETE",
            &format!("/channels/{}/messages/{message_id}", channel.id),
            &alice,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let sent = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            &bob,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "mine",
                "attachment_ids": [attachment_id],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(
        sent.status(),
        StatusCode::OK,
        "bob staged these bytes first and never sent them"
    );
}
