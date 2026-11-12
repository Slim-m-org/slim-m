// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every 429 the limiter produces says how long to wait, from the same refill
//! arithmetic that refused the request.

use axum::http::StatusCode;
use serde_json::json;
use tower::ServiceExt;

use crate::support;
use support::overwrite_harness::{app, new_store, register, request};

/// Sends until the first 429 and returns its `Retry-After` and body hint.
async fn first_refusal(
    router: &axum::Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<serde_json::Value>,
) -> (u64, serde_json::Value) {
    for _ in 0..200 {
        let response = router
            .clone()
            .oneshot(request(method, uri, token, body.clone()))
            .await
            .unwrap();
        if response.status() == StatusCode::TOO_MANY_REQUESTS {
            let header = response
                .headers()
                .get("retry-after")
                .expect("a 429 carries Retry-After")
                .to_str()
                .unwrap()
                .parse()
                .expect("whole seconds");
            let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap();
            return (header, serde_json::from_slice(&bytes).unwrap());
        }
    }
    panic!("{method} {uri} was never refused");
}

#[tokio::test]
async fn a_429_from_any_class_carries_a_plausible_retry_after() {
    let (store, _guard) = new_store("slimm-audit-retry-after").await;
    let (token, _) = register(&store, "root").await;
    let router = app(store);

    let login = json!({"username": "root", "password": "wrong-password-1", "device_name": "x"});
    let (seconds, body) = first_refusal(&router, "POST", "/auth/login", None, Some(login)).await;
    assert!((1..=3600).contains(&seconds), "password class: {seconds}");
    assert_eq!(body["retry_after_seconds"], seconds);

    let (seconds, _) =
        first_refusal(&router, "DELETE", "/invites/zzzzzzzz", Some(&token), None).await;
    assert!((1..=3600).contains(&seconds), "write class: {seconds}");
}
