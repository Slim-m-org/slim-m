// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-channel join-muted default: set through the PATCH route, read back
//! from the channel list, offered at create, and refused without
//! MANAGE_CHANNELS.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, register_token as register, request};

fn patch(channel_id: impl std::fmt::Display, token: &str, join_muted: bool) -> Request<Body> {
    request(
        "PATCH",
        &format!("/channels/{channel_id}"),
        Some(token),
        Some(json!({ "join_muted": join_muted })),
    )
}

async fn listed_join_muted(app: &Router, token: &str, name: &str) -> bool {
    let response = app
        .clone()
        .oneshot(request("GET", "/channels", Some(token), None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    let row = body
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == name)
        .expect("channel is listed");
    row["join_muted"].as_bool().expect("join_muted is present")
}

#[tokio::test]
async fn a_manager_sets_join_muted_alone_and_it_reads_back() {
    let (store, _guard) = support::new_store("slimm-channel-join-muted-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("stage", "voice").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    assert!(!listed_join_muted(&app, &token, "stage").await);

    let response = app
        .clone()
        .oneshot(patch(channel.id, &token, true))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["join_muted"], true);
    assert_eq!(body["name"], "stage");
    assert!(listed_join_muted(&app, &token, "stage").await);

    let response = app
        .clone()
        .oneshot(patch(channel.id, &token, false))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert!(!listed_join_muted(&app, &token, "stage").await);
}

#[tokio::test]
async fn setting_join_muted_without_manage_channels_is_forbidden() {
    let (store, _guard) = support::new_store("slimm-channel-join-muted-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("stage", "voice").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(patch(channel.id, &token, true))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert!(!store.channel(channel.id).await.unwrap().unwrap().join_muted);
}

#[tokio::test]
async fn a_channel_can_be_created_join_muted() {
    let (store, _guard) = support::new_store("slimm-channel-join-muted-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/channels",
            Some(&token),
            Some(json!({ "name": "lecture", "kind": "voice", "join_muted": true })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(json_body(response).await["join_muted"], true);
    assert!(listed_join_muted(&app, &token, "lecture").await);
}

/// Polls until the channel exists and returns the `join_muted` it first showed.
async fn first_seen_join_muted(store: Store, id: ChannelId) -> bool {
    loop {
        if let Some(channel) = store.channel(id).await.unwrap() {
            return channel.join_muted;
        }
        tokio::task::yield_now().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_reader_never_sees_a_join_muted_channel_before_its_flag() {
    let (store, _guard) = support::new_store("slimm-channel-join-muted-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let token = register(&store, "alice").await;

    for round in 0..20 {
        let id = ChannelId::generate();
        let reader = tokio::spawn(first_seen_join_muted(store.clone(), id));
        // A router per round keeps the create inside the write rate limit.
        let response = app(store.clone())
            .oneshot(request(
                "POST",
                "/channels",
                Some(&token),
                Some(json!({
                    "id": id.to_string(),
                    "name": format!("stage-{round}"),
                    "kind": "voice",
                    "join_muted": true,
                })),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert!(
            reader.await.unwrap(),
            "round {round}: a reader saw the channel before join_muted was set"
        );
    }
}
