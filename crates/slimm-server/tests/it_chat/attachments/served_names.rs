// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The name a download carries is the caller's own, and a non-canonical id never answers 500.

use axum::Router;
use axum::http::{StatusCode, header};
use serde_json::json;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::attachments::fixtures::*;

async fn setup() -> (
    Router,
    slimm_server::store::Store,
    String,
    crate::support::TestDbGuard,
) {
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
    let channel = store.create_channel("general", "text").await.unwrap();
    (app(store.clone()), store, channel.id.to_string(), guard)
}

async fn disposition(app: &Router, token: &str, uri: &str) -> String {
    let response = app
        .clone()
        .oneshot(request_plain("GET", uri, token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK, "{uri}");
    response.headers()[header::CONTENT_DISPOSITION]
        .to_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn two_uploads_of_the_same_bytes_each_download_under_their_own_name() {
    let (app, store, _channel, _guard) = setup().await;
    let (alice, _) = register(&store, "alice").await;
    let (bob, _) = register(&store, "bob").await;
    let bytes = png(7);
    let first = upload(&app, &alice, "q3-plan.png", bytes.clone()).await;
    let second = upload(&app, &bob, "probe.png", bytes).await;
    let id = first["id"].as_str().unwrap();
    assert_eq!(id, second["id"].as_str().unwrap());

    let alices = disposition(&app, &alice, &format!("/attachments/{id}")).await;
    let bobs = disposition(&app, &bob, &format!("/attachments/{id}")).await;
    assert!(alices.contains("q3-plan.png"), "{alices}");
    assert!(
        bobs.contains("probe.png") && !bobs.contains("q3-plan"),
        "{bobs}"
    );
    let preview = disposition(&app, &bob, &format!("/attachments/{id}?w=64")).await;
    assert!(!preview.contains("q3-plan"), "{preview}");
}

#[tokio::test]
async fn a_member_who_never_uploaded_the_bytes_sees_the_name_from_a_channel_they_can_view() {
    let (app, store, channel, _guard) = setup().await;
    let (alice, _) = register(&store, "alice").await;
    let (carol, _) = register(&store, "carol").await;
    let uploaded = upload(&app, &alice, "visible.png", png(9)).await;
    let id = uploaded["id"].as_str().unwrap();
    let sent = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{channel}/messages"),
            &alice,
            json!({"id": Uuid::now_v7().to_string(), "content": "x", "attachment_ids": [id]}),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
    let seen = disposition(&app, &carol, &format!("/attachments/{id}")).await;
    assert!(seen.contains("visible.png"), "{seen}");
}

#[tokio::test]
async fn an_uppercase_id_answers_the_file_never_a_500_on_every_path() {
    let (app, store, _channel, _guard) = setup().await;
    let (alice, _) = register(&store, "alice").await;
    let uploaded = upload(&app, &alice, "shot.png", png(11)).await;
    let id = uploaded["id"].as_str().unwrap().to_uppercase();
    for query in ["", "?w=64", "?original=true"] {
        let response = app
            .clone()
            .oneshot(request_plain(
                "GET",
                &format!("/attachments/{id}{query}"),
                &alice,
            ))
            .await
            .unwrap();
        assert!(
            matches!(response.status(), StatusCode::OK | StatusCode::NOT_FOUND),
            "{query}: {}",
            response.status()
        );
    }
}
