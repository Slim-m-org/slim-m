// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member may only have so many attachment downloads open at once: a slow
//! reader holds a file handle and a task until its body ends, so the count of
//! unfinished bodies is capped, not just how fast they start.

use axum::http::StatusCode;
use tower::ServiceExt;

use crate::attachments::fixtures::*;

const CAP: usize = 32;

#[tokio::test]
async fn open_downloads_are_capped_per_member_and_a_finished_one_frees_a_slot() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;
    let uploaded = upload(&app, &token, "clip.png", png(0)).await;
    let uri = format!("/attachments/{}", uploaded["id"].as_str().unwrap());

    let mut open = Vec::new();
    for _ in 0..CAP {
        let response = app
            .clone()
            .oneshot(request_plain("GET", &uri, &token))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        open.push(response);
    }
    let refused = app
        .clone()
        .oneshot(request_plain("GET", &uri, &token))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::TOO_MANY_REQUESTS);

    let (_head, body) = open.pop().unwrap().into_parts();
    let _ = axum::body::to_bytes(body, usize::MAX).await.unwrap();
    let again = app
        .oneshot(request_plain("GET", &uri, &token))
        .await
        .unwrap();
    assert_eq!(again.status(), StatusCode::OK);
}
