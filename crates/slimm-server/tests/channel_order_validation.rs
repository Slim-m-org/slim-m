// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `PUT /channels/order`'s all-or-nothing validation: a missing, unknown, or
//! duplicated channel id, an unknown category id, and a DM refused the same
//! way an unknown id is. Split out of `channel_order.rs` (the happy-path
//! reorder and category-placement tests) to stay under the file budget. See
//! docs/decisions/0006-channel-categories.md.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token as register, request};

/// One group, `category_id: null`, naming every channel - the plain flat
/// shape most of these tests need, since they are about validation rather
/// than category placement.
fn flat_order(channel_ids: &[String]) -> Value {
    json!({ "categories": [{ "category_id": Value::Null, "channel_ids": channel_ids }] })
}

/// A list missing a live channel is refused with a 400 naming it, rather than
/// silently leaving a gap in the order.
#[tokio::test]
async fn reorder_refuses_a_list_missing_a_live_channel() {
    let (store, _guard) = support::new_store("slimm-channel-order-validation-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let a = store.create_channel("a", "text").await.unwrap();
    let b = store.create_channel("b", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(flat_order(&[a.id.to_string()])),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = json_body(response).await;
    let error = body["error"].as_str().unwrap();
    assert!(error.contains("missing"));
    assert!(error.contains(&b.id.to_string()));
}

/// An id that names no live channel is refused, distinctly from a missing one.
#[tokio::test]
async fn reorder_refuses_an_unknown_channel_id() {
    let (store, _guard) = support::new_store("slimm-channel-order-validation-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let a = store.create_channel("a", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let bogus = Uuid::now_v7().to_string();
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(flat_order(&[a.id.to_string(), bogus.clone()])),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = json_body(response).await;
    let error = body["error"].as_str().unwrap();
    assert!(error.contains("unknown"));
    assert!(error.contains(&bogus));
}

/// Repeating one channel and leaving another out entirely is refused, not
/// silently accepted with the repeat's last position winning.
#[tokio::test]
async fn reorder_refuses_a_duplicate_that_also_omits_a_channel() {
    let (store, _guard) = support::new_store("slimm-channel-order-validation-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let a = store.create_channel("a", "text").await.unwrap();
    let b = store.create_channel("b", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(flat_order(&[a.id.to_string(), a.id.to_string()])),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = json_body(response).await;
    assert!(body["error"].as_str().unwrap().contains(&b.id.to_string()));
}

/// A duplicate that still names every live channel at least once is refused
/// too: the length itself has to match, or a duplicate could silently pin
/// one channel's position while displacing nothing else's slot count. Split
/// across two groups, so this also covers a repeat spanning categories.
#[tokio::test]
async fn reorder_refuses_a_duplicate_that_names_every_channel() {
    let (store, _guard) = support::new_store("slimm-channel-order-validation-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let a = store.create_channel("a", "text").await.unwrap();
    let b = store.create_channel("b", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(json!({
                "categories": [
                    { "category_id": Value::Null, "channel_ids": [a.id.to_string(), b.id.to_string()] },
                    { "category_id": Value::Null, "channel_ids": [a.id.to_string()] },
                ]
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// A DM is never in the ordered set: naming it is refused the same way an
/// unknown id is, and it never has to appear in a valid list.
#[tokio::test]
async fn reorder_never_names_a_dm_channel() {
    let (store, _guard) = support::new_store("slimm-channel-order-validation-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let a = store.create_channel("a", "text").await.unwrap();
    let alice = store.create_user("alice", "alice").await.unwrap();
    let bob = store.create_user("bob", "bob").await.unwrap();
    let dm = store.open_dm(alice.id, bob.id).await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "carol").await;

    // The DM is not required alongside `a`.
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(flat_order(&[a.id.to_string()])),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    // Naming it anyway is refused, like any other unknown id.
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(flat_order(&[a.id.to_string(), dm.id.to_string()])),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// A category id that names no live category is refused, the same shape an
/// unknown channel id already is - checked before anything is written.
#[tokio::test]
async fn reorder_refuses_an_unknown_category_id() {
    let (store, _guard) = support::new_store("slimm-channel-order-validation-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let a = store.create_channel("a", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let bogus = Uuid::now_v7().to_string();
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(json!({
                "categories": [{ "category_id": bogus.clone(), "channel_ids": [a.id.to_string()] }]
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = json_body(response).await;
    let error = body["error"].as_str().unwrap();
    assert!(error.contains("unknown"));
    assert!(error.contains(&bogus));
}

/// A body naming neither `channel_ids` nor `categories` cannot mean anything,
/// so it is a 400 rather than silently matching one shape or the other.
#[tokio::test]
async fn reorder_refuses_a_body_naming_neither_shape() {
    let (store, _guard) = support::new_store("slimm-channel-order-validation-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    store.create_channel("a", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(json!({})),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = json_body(response).await;
    assert!(
        body["error"]
            .as_str()
            .unwrap()
            .contains("channel_ids or categories")
    );
}

/// A body naming both shapes at once is refused too, rather than one
/// silently winning over the other with no way for the caller to tell which.
#[tokio::test]
async fn reorder_refuses_a_body_naming_both_shapes() {
    let (store, _guard) = support::new_store("slimm-channel-order-validation-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let a = store.create_channel("a", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(json!({
                "channel_ids": [a.id.to_string()],
                "categories": [{ "category_id": Value::Null, "channel_ids": [a.id.to_string()] }],
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = json_body(response).await;
    assert!(body["error"].as_str().unwrap().contains("not both"));
}
