// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A slow or oversized audited body reaches the handler whole; the log is built from what the handler read.

use std::time::Duration;

use axum::Router;
use axum::body::{Body, Bytes};
use axum::http::Request;
use futures_util::stream;
use serde_json::Value;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::support;
use support::app::{app, json_body};

async fn admin_and_role() -> (Router, String, String, support::TestDbGuard) {
    let (store, guard) = support::new_store("slimm-audit-slow-body").await;
    let admin_role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = store.create_user("root", "Root").await.unwrap();
    store.assign_role(admin.id, admin_role).await.unwrap();
    let token = store
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let role = store
        .create_role("mods", Permissions::NONE, false)
        .await
        .unwrap();
    (app(store), token, role.to_string(), guard)
}

fn patch(role: &str, token: &str, body: Body) -> Request<Body> {
    send("PATCH", &format!("/roles/{role}"), token, body)
}

fn send(method: &str, uri: &str, token: &str, body: Body) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(body)
        .unwrap()
}

async fn newest_row(router: &Router, token: &str) -> Value {
    let request = Request::builder()
        .uri("/space/audit-log")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let response = router.clone().oneshot(request).await.unwrap();
    json_body(response).await[0].clone()
}

#[tokio::test]
async fn a_body_that_stalls_midway_still_reaches_the_handler_and_the_log_whole() {
    let (router, token, role, _guard) = admin_and_role().await;
    let slow = stream::unfold(0, |step| async move {
        match step {
            0 => Some((
                Ok::<_, std::io::Error>(Bytes::from_static(b"{\"name\":\"sl")),
                1,
            )),
            1 => {
                tokio::time::sleep(Duration::from_millis(600)).await;
                Some((Ok(Bytes::from_static(b"owed\"}")), 2))
            }
            _ => None,
        }
    });

    let response = router
        .clone()
        .oneshot(patch(&role, &token, Body::from_stream(slow)))
        .await
        .unwrap();

    assert!(response.status().is_success(), "{}", response.status());
    let row = newest_row(&router, &token).await;
    assert_eq!(row["detail"]["name"], "slowed", "{row}");
    assert!(row["detail"].get("uninspected").is_none(), "{row}");
}
