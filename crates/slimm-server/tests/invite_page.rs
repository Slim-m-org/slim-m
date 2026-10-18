// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The https invite link: `GET /invite/{code}` renders a landing page for a
//! usable code and one fixed page for everything else.

use axum::http::StatusCode;
use axum::response::Response;
use slimm_server::ids::UserId;
use tower::ServiceExt;

mod support;
use support::overwrite_harness::{app, new_store, register};

async fn fetch(router: &axum::Router, uri: &str) -> (StatusCode, String, Response<()>) {
    let request = axum::http::Request::builder()
        .uri(uri)
        .header("host", "chat.example")
        .header("x-forwarded-proto", "https")
        .body(axum::body::Body::empty())
        .unwrap();
    let response = router.clone().oneshot(request).await.unwrap();
    let (parts, body) = response.into_parts();
    let bytes = axum::body::to_bytes(body, usize::MAX).await.unwrap();
    (
        parts.status,
        String::from_utf8(bytes.to_vec()).unwrap(),
        Response::from_parts(parts, ()),
    )
}

#[tokio::test]
async fn usable_code_renders_the_landing_page() {
    let (store, _guard) = new_store("slimm-invite-page").await;
    let (_, admin_id) = register(&store, "root").await;
    let router = app(store.clone());
    let code = store
        .create_invite(UserId(admin_id.parse().unwrap()), None, None, None)
        .await
        .unwrap()
        .code;

    let (status, html, parts) = fetch(&router, &format!("/invite/{}", code.to_uppercase())).await;

    assert_eq!(status, StatusCode::OK);
    assert!(html.contains(&format!(
        "slimm://join?server=https%3A%2F%2Fchat.example&amp;code={code}"
    )));
    assert!(html.contains(&format!(
        "/app/join?server=https%3A%2F%2Fchat.example&amp;code={code}"
    )));
    assert_eq!(parts.headers()["referrer-policy"], "no-referrer");
    assert!(
        parts.headers()["content-security-policy"]
            .to_str()
            .unwrap()
            .contains("frame-ancestors 'none'")
    );
}

#[tokio::test]
async fn unusable_codes_are_indistinguishable() {
    let (store, _guard) = new_store("slimm-invite-page-bad").await;
    let (_, admin_id) = register(&store, "root").await;
    let router = app(store.clone());
    let admin = UserId(admin_id.parse().unwrap());
    let revoked = store
        .create_invite(admin, None, None, None)
        .await
        .unwrap()
        .code;
    store.revoke_invite(&revoked, None).await.unwrap();

    let (status_a, html_a, _) = fetch(&router, &format!("/invite/{revoked}")).await;
    let (status_b, html_b, _) = fetch(&router, "/invite/neverissued").await;

    assert_eq!(status_a, StatusCode::NOT_FOUND);
    assert_eq!(status_b, StatusCode::NOT_FOUND);
    assert_eq!(html_a, html_b);
    assert!(!html_a.contains("slimm://"));
}
