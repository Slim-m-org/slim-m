// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! When a frame is published at all: not for a replay, not for an op that
//! changed nothing, and without disconnecting a text-only connection.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::http;
use tower::ServiceExt;

use crate::fixtures::{connect, new_store, read_frame, serve, user_ticket};
use crate::requests::{clear_request, place_request};
use crate::support;

/// A retry after a lost response must not repaint the object on every other
/// screen, which is what an unconditional publish would do.
#[tokio::test]
async fn an_idempotent_replay_publishes_nothing() {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (access, ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let addr = serve(state.clone()).await;
    let mut ws = connect(addr, &ticket).await;

    let request = place_request(channel, &access);
    let (parts, body) = request.into_parts();
    let bytes = axum::body::to_bytes(body, usize::MAX).await.unwrap();
    let again = Request::from_parts(parts.clone(), Body::from(bytes.clone()));
    let first = Request::from_parts(parts, Body::from(bytes));

    assert_eq!(
        http::router(state.clone())
            .oneshot(first)
            .await
            .unwrap()
            .status(),
        StatusCode::CREATED
    );
    let frame = read_frame(&mut ws).await;
    assert_eq!(frame["type"], "canvas.object.placed");

    assert_eq!(
        http::router(state.clone())
            .oneshot(again)
            .await
            .unwrap()
            .status(),
        StatusCode::CREATED
    );
    let second = tokio::time::timeout(Duration::from_millis(300), read_frame(&mut ws)).await;
    assert!(second.is_err(), "a replay must broadcast nothing");
}

/// The hub is one broadcast channel for the entire deployment and a lagging
/// subscriber is closed, not skipped, so somebody scribbling has to be unable
/// to knock a text-only connection off its socket.
#[tokio::test]
async fn a_canvas_burst_does_not_disconnect_a_text_only_connection() {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (alice_access, _alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    for _ in 0..60 {
        let response = http::router(state.clone())
            .oneshot(place_request(channel, &alice_access))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
    }

    let mut seen = 0;
    for _ in 0..60 {
        let frame = read_frame(&mut bob_ws).await;
        assert_ne!(
            frame["type"], "error",
            "the burst closed a connection instead of being delivered",
        );
        if frame["type"] == "canvas.object.placed" {
            seen += 1;
        }
    }
    assert_eq!(seen, 60);
}

/// An affected-0 op is a real state transition that never happened, so it
/// must not fan a frame out to anybody, the same guarantee an idempotent
/// replay already gets.
#[tokio::test]
async fn an_op_that_changes_nothing_publishes_no_frame() {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;

    let response = http::router(state.clone())
        .oneshot(clear_request(channel, &alice_access, 0))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);

    let next = tokio::time::timeout(Duration::from_millis(300), read_frame(&mut alice_ws)).await;
    assert!(next.is_err(), "an affected-0 clear must publish nothing");
}
