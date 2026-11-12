// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A panicking request handler answers 500 and the server keeps serving; a
//! panic off the request task is still marked to end the process.

use axum::Router;
use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use axum::routing::get;
use slimm_server::http::{guard_panics, panic_guard};
use tower::ServiceExt;

async fn boom() -> &'static str {
    panic!("a handler bug")
}

/// Reports, from inside the handler, whether a panic here or in a task it spawns would end the process.
async fn where_am_i() -> String {
    let spawned = tokio::spawn(async { panic_guard::panic_ends_process() })
        .await
        .unwrap();
    format!("{} {}", panic_guard::panic_ends_process(), spawned)
}

fn app() -> Router {
    guard_panics(
        Router::new()
            .route("/boom", get(boom))
            .route("/ok", get(|| async { "ok" }))
            .route("/where", get(where_am_i)),
    )
}

async fn get_status(app: &Router, uri: &str) -> (StatusCode, String) {
    let request = Request::builder().uri(uri).body(Body::empty()).unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let body = to_bytes(response.into_body(), 1 << 16).await.unwrap();
    (status, String::from_utf8_lossy(&body).into_owned())
}

#[tokio::test]
async fn a_panicking_handler_answers_the_internal_error_and_the_next_request_is_served() {
    let app = app();
    let (status, body) = get_status(&app, "/boom").await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert!(body.contains("internal error"), "{body}");

    let (status, body) = get_status(&app, "/ok").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, "ok");
}

#[tokio::test]
async fn only_a_panic_on_the_request_task_is_kept_alive() {
    assert!(panic_guard::panic_ends_process(), "outside any request");
    let (status, body) = get_status(&app(), "/where").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body, "false true",
        "request task kept, spawned task still aborts"
    );
}
