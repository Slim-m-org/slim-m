// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The routes that take a base64 package or image pack as a JSON body run under
//! their own, longer request timeout instead of the 30 s one.

use std::time::Duration;

use axum::body::{Body, Bytes};
use axum::http::{Request, StatusCode};
use slimm_server::http::router_with_slow_body_timeout;
use tower::ServiceExt;

use crate::support;
use support::app::{builder, register_token};

const SLOW_ROUTES: [&str; 4] = [
    "/emoji/bulk",
    "/space/dock/packages/preview",
    "/space/dock/packages/install",
    "/space/themes",
];

#[tokio::test]
async fn large_json_routes_use_the_slow_body_timeout_not_the_default() {
    let (store, _guard) = support::new_store("slimm-slow-body-test").await;
    let token = register_token(&store, "alice").await;
    let state = builder(store).build();
    for uri in SLOW_ROUTES {
        let stream = futures_util::stream::unfold(0usize, |i| async move {
            if i >= 4 {
                return None;
            }
            if i > 0 {
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
            Some((
                Ok::<_, std::io::Error>(Bytes::from_static(b"{\"x\":")),
                i + 1,
            ))
        });
        let request = Request::builder()
            .method("POST")
            .uri(uri)
            .header("authorization", format!("Bearer {token}"))
            .header("content-type", "application/json")
            .body(Body::from_stream(stream))
            .unwrap();
        let started = tokio::time::Instant::now();
        let app = router_with_slow_body_timeout(state.clone(), Duration::from_millis(1500));
        let status = app.oneshot(request).await.unwrap().status();
        assert_eq!(
            status,
            StatusCode::GATEWAY_TIMEOUT,
            "{uri} after {:?}",
            started.elapsed()
        );
        assert!(
            started.elapsed() < Duration::from_millis(2800),
            "{uri} cut only after {:?}",
            started.elapsed()
        );
    }
}
