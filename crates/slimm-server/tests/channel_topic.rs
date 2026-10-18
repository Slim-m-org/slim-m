// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel topics: gated on the same MANAGE_CHANNELS check renaming uses, a
//! server-side length ceiling, and round-tripping through both the PATCH
//! response and the channel list. Split out from `channels.rs` (rename and
//! soft-delete) the same way `message_delete.rs` and `message_search.rs`
//! split off from `message_endpoints.rs`: one file per concern.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, register_token as register, request};

/// Setting a topic is gated on the same MANAGE_CHANNELS check renaming uses,
/// and the new topic round-trips through both the PATCH response and a
/// subsequent `GET /channels` list - the actual read path a client's channel
/// header uses.
#[tokio::test]
async fn manager_can_set_a_topic_and_it_round_trips_through_the_list() {
    let (store, _guard) = support::new_store("slimm-channel-topic-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", channel.id),
            Some(&token),
            Some(json!({ "topic": "compose files, dead drives, and things that were fine yesterday" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(
        body["topic"],
        "compose files, dead drives, and things that were fine yesterday"
    );
    // The name was not in this request, so it must be untouched.
    assert_eq!(body["name"], "general");

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/channels", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    let listed = listed.as_array().unwrap();
    let general = listed
        .iter()
        .find(|c| c["id"] == channel.id.to_string())
        .unwrap();
    assert_eq!(
        general["topic"],
        "compose files, dead drives, and things that were fine yesterday"
    );
}

/// A channel with no topic set answers `null`, not an absent field or an
/// empty string, matching [`Store::update_channel`]'s "no topic" state.
#[tokio::test]
async fn a_fresh_channel_has_no_topic() {
    let (store, _guard) = support::new_store("slimm-channel-topic-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/channels", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    let general = listed
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == channel.id.to_string())
        .unwrap();
    assert!(general["topic"].is_null());
}

/// A blank topic clears it back to `null` rather than storing an empty
/// string - the convention that lets a single `Option<String>` request field
/// carry "clear it" without a separate tri-state signal.
#[tokio::test]
async fn a_blank_topic_clears_it() {
    let (store, _guard) = support::new_store("slimm-channel-topic-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    app.clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", channel.id),
            Some(&token),
            Some(json!({ "topic": "temporary" })),
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", channel.id),
            Some(&token),
            Some(json!({ "topic": "   " })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert!(body["topic"].is_null());
}

/// A member without MANAGE_CHANNELS cannot set a topic, the same gate that
/// already refuses them a rename.
#[tokio::test]
async fn setting_a_topic_without_manage_channels_is_forbidden() {
    let (store, _guard) = support::new_store("slimm-channel-topic-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", channel.id),
            Some(&token),
            Some(json!({ "topic": "a new topic" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// A topic past the server-side length ceiling is refused, regardless of
/// what any client-side limit would have allowed.
#[tokio::test]
async fn a_topic_over_the_length_ceiling_is_rejected() {
    let (store, _guard) = support::new_store("slimm-channel-topic-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", channel.id),
            Some(&token),
            Some(json!({ "topic": "x".repeat(257) })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// A PATCH with neither `name` nor `topic` has nothing to do and is rejected
/// rather than silently succeeding as a no-op.
#[tokio::test]
async fn an_update_with_neither_field_is_rejected() {
    let (store, _guard) = support::new_store("slimm-channel-topic-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", channel.id),
            Some(&token),
            Some(json!({})),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}
