// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Signed download links: a browser saves a large file natively without a bearer header.

use axum::http::{HeaderMap, StatusCode};
use serde_json::json;
use tower::ServiceExt;

use crate::support;
use crate::support::app::request;
use support::exports::{World, account, upload_png, world};

async fn link(w: &World, token: &str, body: serde_json::Value) -> (StatusCode, String) {
    let (status, json) = w.call("POST", "/downloads/links", token, Some(body)).await;
    let path = json["path"].as_str().unwrap_or_default().to_owned();
    (status, path)
}

async fn redeem(w: &World, path: &str, range: Option<&str>) -> (StatusCode, HeaderMap, Vec<u8>) {
    let mut builder = axum::http::Request::builder().uri(path);
    if let Some(range) = range {
        builder = builder.header("range", range);
    }
    let response = w
        .router
        .clone()
        .oneshot(builder.body(axum::body::Body::empty()).unwrap())
        .await
        .unwrap();
    let (status, headers) = (response.status(), response.headers().clone());
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, headers, bytes.to_vec())
}

#[tokio::test]
async fn an_export_link_saves_the_archive_without_a_bearer_token() {
    let (store, _guard) = support::new_store("slimm-link-export").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let job = w.export(&alice, "member").await;
    let id = job["id"].as_str().unwrap();
    let (_, expected) = w.download(&alice, id).await;

    let (status, path) = link(&w, &alice, json!({ "kind": "export", "id": id })).await;
    assert_eq!(status, StatusCode::OK);
    let (status, headers, bytes) = redeem(&w, &path, None).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(bytes, expected);
    let disposition = headers["content-disposition"].to_str().unwrap();
    assert!(disposition.starts_with("attachment"), "{disposition}");
    let (status, _, part) = redeem(&w, &path, Some("bytes=0-9")).await;
    assert_eq!(status, StatusCode::PARTIAL_CONTENT);
    assert_eq!(part, expected[..10]);
}

#[tokio::test]
async fn an_image_link_is_a_forced_download_not_an_inline_view() {
    let (store, _guard) = support::new_store("slimm-link-image").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let attachment = upload_png(&w, &alice).await;
    let inline = w
        .router
        .clone()
        .oneshot(request(
            "GET",
            &format!("/attachments/{attachment}"),
            Some(&alice),
            None,
        ))
        .await
        .unwrap();
    assert!(
        inline.headers()["content-disposition"]
            .to_str()
            .unwrap()
            .starts_with("inline")
    );

    let (status, path) = link(
        &w,
        &alice,
        json!({ "kind": "attachment", "id": attachment }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, headers, _) = redeem(&w, &path, None).await;

    assert_eq!(status, StatusCode::OK);
    assert!(
        headers["content-disposition"]
            .to_str()
            .unwrap()
            .starts_with("attachment; filename=\"pixel.png\"")
    );
}

#[tokio::test]
async fn nobody_gets_a_link_to_what_they_cannot_download() {
    let (store, _guard) = support::new_store("slimm-link-refused").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let hash = password_hash().await;
    let bob = store
        .create_account("bob", "bob", &hash)
        .await
        .map(|a| a.id)
        .unwrap();
    let bob = store.open_session(bob, "cli").await.unwrap().access_token;
    let export = w.export(&alice, "member").await;
    let attachment = upload_png(&w, &alice).await;

    let (status, _) = link(
        &w,
        &bob,
        json!({ "kind": "export", "id": export["id"].as_str().unwrap() }),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = link(&w, &bob, json!({ "kind": "attachment", "id": attachment })).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn an_altered_link_and_a_link_to_a_deleted_export_are_refused() {
    let (store, _guard) = support::new_store("slimm-link-tamper").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let job = w.export(&alice, "member").await;
    let id = job["id"].as_str().unwrap();
    let (_, path) = link(&w, &alice, json!({ "kind": "export", "id": id })).await;

    let altered = format!("{path}x");
    assert_eq!(redeem(&w, &altered, None).await.0, StatusCode::NOT_FOUND);
    assert_eq!(
        redeem(&w, "/downloads/not-a-link", None).await.0,
        StatusCode::NOT_FOUND
    );
    w.call("DELETE", &format!("/exports/{id}"), &alice, None)
        .await;
    assert_eq!(
        redeem(&w, &path, None).await.0,
        StatusCode::NOT_FOUND,
        "a link is checked again when it is used"
    );
    let (status, _) = link(&w, "wrong-token", json!({ "kind": "export", "id": id })).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

async fn password_hash() -> String {
    slimm_server::auth::Auth::new(2)
        .unwrap()
        .hash_password("correct-horse-battery".to_owned())
        .await
        .unwrap()
}
