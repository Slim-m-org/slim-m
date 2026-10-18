// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `PUT /channels/order`: the MANAGE_CHANNELS gate, the position and
//! category this actually writes, the no-op case that changes nothing, and a
//! cross-category drag. See `channel_order_validation.rs` for the
//! all-or-nothing validation half, split out to stay under the file budget,
//! and docs/decisions/0006-channel-categories.md for the design.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::store::ChannelOrderGroup;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, register_token as register, request};

fn ids(listed: &Value) -> Vec<String> {
    listed
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["id"].as_str().unwrap().to_owned())
        .collect()
}

async fn channels_of(app: &Router, token: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request("GET", "/channels", Some(token), None))
            .await
            .unwrap(),
    )
    .await
}

/// One group, `category_id: null`, naming every channel - the plain flat
/// shape most of these tests need, since they are about ordering rather than
/// category placement.
fn flat_order(channel_ids: &[String]) -> Value {
    json!({ "categories": [{ "category_id": Value::Null, "channel_ids": channel_ids }] })
}

/// The pre-category wire shape every client sent before docs/decisions/
/// 0006-channel-categories.md: a flat list, with no `categories` key at all -
/// what [`flat_order`] emulates through the grouped shape's own null-category
/// group, and what an old client actually still sends.
fn old_shape(channel_ids: &[String]) -> Value {
    json!({ "channel_ids": channel_ids })
}

#[tokio::test]
async fn manager_can_reorder_channels() {
    let (store, _guard) = support::new_store("slimm-channel-order-test").await;
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
    let c = store.create_channel("c", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let new_order = vec![c.id.to_string(), a.id.to_string(), b.id.to_string()];
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(flat_order(&new_order)),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(ids(&body), new_order);
    let positions: Vec<i64> = body
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["position"].as_i64().unwrap())
        .collect();
    assert_eq!(positions, vec![0, 1, 2]);

    // Persisted, not just echoed back.
    let listed = channels_of(&app, &token).await;
    assert_eq!(ids(&listed), new_order);
}

/// A freshly created channel always lands at the end of the order, not at
/// position 0: `create_channel` has to read the live maximum in the same
/// transaction, or a new channel would collide with (and sort before, on the
/// `created_at` tiebreak) whichever channel already held position 0.
#[tokio::test]
async fn a_new_channel_is_appended_after_a_reorder_has_run() {
    let (store, _guard) = support::new_store("slimm-channel-order-test").await;
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

    // Reverse the order, so "a" (created first) now holds position 1, not 0.
    app.clone()
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(flat_order(&[b.id.to_string(), a.id.to_string()])),
        ))
        .await
        .unwrap();

    let created = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/channels",
                Some(&token),
                Some(json!({ "name": "c" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(created["position"].as_i64().unwrap(), 2);

    let listed = channels_of(&app, &token).await;
    assert_eq!(
        ids(&listed),
        vec![
            b.id.to_string(),
            a.id.to_string(),
            created["id"].as_str().unwrap().to_owned(),
        ]
    );
}

#[tokio::test]
async fn reordering_without_manage_channels_is_forbidden() {
    let (store, _guard) = support::new_store("slimm-channel-order-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
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
            Some(flat_order(&[b.id.to_string(), a.id.to_string()])),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// Submitting the arrangement the deployment already has changes nothing and
/// still answers 200 with that same order - not an error, and not a claim
/// that something moved when it did not.
#[tokio::test]
async fn reordering_to_the_same_order_is_a_no_op() {
    let (store, _guard) = support::new_store("slimm-channel-order-test").await;
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

    let same_order = vec![a.id.to_string(), b.id.to_string()];
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(flat_order(&same_order)),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(ids(&json_body(response).await), same_order);
}

/// A drag from one category's section to another's reassigns `category_id`
/// and repositions in the one request, atomically - the property the
/// decision record calls out as the reason the payload is grouped rather
/// than a move followed by a reorder.
#[tokio::test]
async fn a_cross_category_drag_reassigns_and_repositions_atomically() {
    let (store, _guard) = support::new_store("slimm-channel-order-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let voice_cat = store.create_category("Voice").await.unwrap();
    let text_cat = store.create_category("Text").await.unwrap();
    let a = store.create_channel("a", "voice").await.unwrap();
    let b = store.create_channel("b", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    // `a` (a voice channel) drags into the Text section, ahead of `b`.
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(json!({
                "categories": [
                    { "category_id": text_cat.id.to_string(),
                      "channel_ids": [a.id.to_string(), b.id.to_string()] },
                    { "category_id": voice_cat.id.to_string(), "channel_ids": [] },
                ]
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    let moved_a = body
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == a.id.to_string())
        .unwrap();
    assert_eq!(moved_a["category_id"], text_cat.id.to_string());
    assert_eq!(moved_a["position"].as_i64().unwrap(), 0);

    // Persisted, not just echoed back.
    let listed = channels_of(&app, &token).await;
    let persisted_a = listed
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == a.id.to_string())
        .unwrap();
    assert_eq!(persisted_a["category_id"], text_cat.id.to_string());
}

/// A client that has never heard of categories keeps working against a
/// server that has: `channel_ids` alone reorders positions and never
/// touches any channel's `category_id`. The wire is additive-only, so this
/// pre-category shape must keep validating and applying forever, not just
/// until the next client update reaches every phone.
#[tokio::test]
async fn an_old_client_sending_channel_ids_alone_still_reorders_and_keeps_categories() {
    let (store, _guard) = support::new_store("slimm-channel-order-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let text_cat = store.create_category("Text").await.unwrap();
    let a = store.create_channel("a", "text").await.unwrap();
    let b = store.create_channel("b", "voice").await.unwrap();
    // Both in one category: `list_channels` sorts by category position first, so two channels in different categories could never swap order by position alone.
    store
        .reorder_channels(&[ChannelOrderGroup {
            category_id: Some(text_cat.id),
            channel_ids: vec![a.id, b.id],
        }])
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let new_order = vec![b.id.to_string(), a.id.to_string()];
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/channels/order",
            Some(&token),
            Some(old_shape(&new_order)),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(ids(&body), new_order);

    let category_of = |list: &Value, id: &str| -> Option<String> {
        list.as_array()
            .unwrap()
            .iter()
            .find(|c| c["id"] == id)
            .unwrap()["category_id"]
            .as_str()
            .map(str::to_owned)
    };
    assert_eq!(
        category_of(&body, &a.id.to_string()),
        Some(text_cat.id.to_string()),
        "an old client's reorder must not touch category_id"
    );
    assert_eq!(
        category_of(&body, &b.id.to_string()),
        Some(text_cat.id.to_string()),
        "an old client's reorder must not touch category_id"
    );

    // Persisted, not just echoed back.
    let listed = channels_of(&app, &token).await;
    assert_eq!(ids(&listed), new_order);
    assert_eq!(
        category_of(&listed, &a.id.to_string()),
        Some(text_cat.id.to_string())
    );
}
