// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A connection reuses the viewer's block list across reaction events, so a
//! block or unblock made over HTTP must show in the very next frame.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::http::{self, AppState};
use slimm_server::permissions::Permissions;
use slimm_server::store::NewMessage;
use tower::ServiceExt;

mod support;

use support::ws::{Client, connect, read_frame, serve, user_ticket};

async fn next_reactions(ws: &mut Client) -> Vec<Value> {
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(3), read_frame(ws))
            .await
            .expect("no reactions.changed frame arrived");
        if frame["type"] == "reactions.changed" {
            return frame["reactions"].as_array().unwrap().clone();
        }
    }
}

async fn call(state: &AppState, method: &str, uri: &str, token: &str) {
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method(method)
                .uri(uri)
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT, "{method} {uri}");
}

#[tokio::test]
async fn a_block_made_between_two_reactions_applies_to_the_second() {
    let (store, _guard) = support::new_store("slimm-blocking-live-cache").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ADD_REACTIONS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());
    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (pest_access, _ticket, pest) = user_ticket(&store, "pest").await;
    let message = store
        .send_message(NewMessage::plain(
            channel.id,
            alice,
            slimm_server::ids::MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap()
        .message
        .id;
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let react = |emoji: &str| format!("/messages/{message}/reactions/{emoji}");

    call(&state, "PUT", &react(":wave:"), &pest_access).await;
    assert_eq!(
        next_reactions(&mut alice_ws).await.len(),
        1,
        "not blocked yet"
    );

    call(&state, "POST", &format!("/blocks/{pest}"), &alice_access).await;
    call(&state, "PUT", &react(":tada:"), &pest_access).await;
    assert!(
        next_reactions(&mut alice_ws).await.is_empty(),
        "the block must apply to the next frame"
    );

    call(&state, "DELETE", &format!("/blocks/{pest}"), &alice_access).await;
    call(&state, "PUT", &react(":heart:"), &pest_access).await;
    assert_eq!(
        next_reactions(&mut alice_ws).await.len(),
        3,
        "the unblock must apply to the next frame"
    );
}
