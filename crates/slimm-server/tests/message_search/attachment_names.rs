// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A message that is only a file is found by the file's name, including from
//! text such as `.iso` that is not FTS5 syntax on its own.

use axum::http::StatusCode;
use serde_json::Value;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::fixtures::*;

async fn search(app: &axum::Router, channel_id: &str, token: &str, q: &str) -> Vec<Value> {
    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/messages/search?q={q}"),
            Some(token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK, "q={q}");
    json_body(response).await.as_array().unwrap().clone()
}

#[tokio::test]
async fn a_file_only_message_is_found_by_its_file_name() {
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
    let token = register(&store, "alice").await;
    let channel_id = channel.id.to_string();

    let iso = upload_named(&app, &token, "ubuntu-24.04.iso").await;
    send_with_attachments(&app, &channel_id, &token, "", &[&iso]).await;
    send(&app, &channel_id, &token, "unrelated words").await;

    for q in [".iso", "ubuntu", "iso"] {
        let found = search(&app, &channel_id, &token, q).await;
        assert_eq!(found.len(), 1, "q={q}");
        assert_eq!(found[0]["matched_attachment_id"], iso.as_str(), "q={q}");
    }
    assert!(search(&app, &channel_id, &token, "...").await.is_empty());
}
