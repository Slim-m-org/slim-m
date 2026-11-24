// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An account holds at most 50 live sessions: a sign-in past that revokes the oldest, its
//! push registration and its socket with it.

use std::time::Duration;

use axum::http::StatusCode;
use futures_util::StreamExt;
use serde_json::json;
use slimm_server::auth::Auth;
use slimm_server::http;
use slimm_server::store::{IssuedTokens, PushRegistration, Store};
use tokio_tungstenite::tungstenite::Message as WsMessage;

use crate::support;
use support::app::call;
use support::ws::{connect, serve};

const PASSWORD: &str = "correct-horse-battery";
const CAP: usize = 50;

async fn register_push(store: &Store, tokens: &IssuedTokens, push_token: &str) {
    let registration = PushRegistration {
        platform: "ios",
        push_token,
        voip_push_token: None,
        push_public_key: &[7u8; 32],
        include_content: Some(false),
        include_content_chosen: true,
    };
    store
        .register_push(tokens.user_id, tokens.device_id, registration)
        .await
        .unwrap();
}

async fn is_live(store: &Store, tokens: &IssuedTokens) -> bool {
    store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .is_some()
}

#[tokio::test]
async fn the_51st_sign_in_revokes_the_oldest_session_and_closes_its_socket() {
    let (store, _db) = support::new_store("slimm-session-cap").await;
    let state = support::app::state(store.clone());
    let hash = Auth::new(2)
        .unwrap()
        .hash_password(PASSWORD.to_owned())
        .await
        .unwrap();
    let alice = store.create_account("alice", "Alice", &hash).await.unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let mut held = Vec::with_capacity(CAP);
    for n in 0..CAP {
        held.push(
            store
                .open_session(alice.id, &format!("d{n}"))
                .await
                .unwrap(),
        );
    }
    register_push(&store, &held[0], "oldest-push").await;
    register_push(&store, &held[1], "next-push").await;
    let ctx = store
        .authenticate(&held[0].access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _) = store.mint_ws_ticket(&ctx).await.unwrap();
    let mut oldest_ws = connect(serve(state.clone()).await, &ticket).await;

    let body = json!({ "username": "alice", "password": PASSWORD, "device_name": "new" });
    let router = http::router(state);
    let (status, body) = call(&router, "POST", "/auth/login", None, Some(body)).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(
        !is_live(&store, &held[0]).await,
        "the oldest session is revoked"
    );
    assert!(is_live(&store, &held[1]).await, "only the oldest one goes");
    assert_eq!(store.live_session_ids(alice.id).await.unwrap().len(), CAP);
    let targets = store.push_targets(&[alice.id]).await.unwrap();
    let devices: Vec<_> = targets.iter().map(|t| t.device_id).collect();
    assert_eq!(
        devices,
        vec![held[1].device_id],
        "the oldest device stops being pushed"
    );
    let closed = tokio::time::timeout(Duration::from_secs(2), async {
        while let Some(Ok(frame)) = oldest_ws.next().await {
            if matches!(frame, WsMessage::Close(_)) {
                return;
            }
        }
    })
    .await;
    assert!(
        closed.is_ok(),
        "the revoked oldest session loses its socket"
    );
}

#[tokio::test]
async fn a_sign_in_under_the_cap_revokes_nothing() {
    let (store, _db) = support::new_store("slimm-session-cap").await;
    let alice = store
        .create_account("alice", "Alice", "unused")
        .await
        .unwrap();
    let mut held = Vec::new();
    for n in 0..CAP {
        held.push(
            store
                .open_session(alice.id, &format!("d{n}"))
                .await
                .unwrap(),
        );
    }

    for tokens in &held {
        assert!(is_live(&store, tokens).await);
    }
    assert!(held.iter().all(|t| t.replaced.is_empty()));
}
