// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `PUT /channels/order` for a manager who cannot see every channel: they can
//! reorder what they see, the channels they cannot see keep their place, and
//! nothing in the answer reveals those channels.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, register_token as register, request};

async fn setup() -> (Store, support::TestDbGuard, Router, String) {
    let (store, guard) = support::new_store("slimm-channel-order-hidden").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let everyone_id = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .unwrap()
        .id;
    for name in ["a", "b"] {
        store.create_channel(name, "text").await.unwrap();
    }
    let hidden = store.create_channel("secret-staff", "text").await.unwrap();
    store.create_channel("c", "text").await.unwrap();
    store
        .set_role_overwrite(
            hidden.id,
            everyone_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let member = register(&store, "bob").await;
    (store, guard, app, member)
}

fn names(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap().to_owned())
        .collect()
}

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

async fn put_order(app: &Router, token: &str, body: Value) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request("PUT", "/channels/order", Some(token), Some(body)))
        .await
        .unwrap();
    (response.status(), json_body(response).await)
}

async fn stored_order(store: &Store) -> Vec<String> {
    store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .map(|c| c.name)
        .collect()
}

#[tokio::test]
async fn a_manager_reorders_what_they_see_and_hidden_channels_keep_their_slot() {
    let (store, _guard, app, token) = setup().await;
    let listed = channels_of(&app, &token).await;
    assert_eq!(names(&listed), ["a", "b", "c"], "GET /channels hides it");

    let mut order = ids(&listed);
    order.reverse();
    let (status, body) = put_order(&app, &token, json!({ "channel_ids": order })).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        names(&body),
        ["c", "b", "a"],
        "the answer is what they can list"
    );
    assert_eq!(
        stored_order(&store).await,
        ["c", "b", "secret-staff", "a"],
        "the hidden channel stays at index 2"
    );
}

#[tokio::test]
async fn the_grouped_shape_keeps_hidden_channels_in_place_too() {
    let (store, _guard, app, token) = setup().await;
    let mut order = ids(&channels_of(&app, &token).await);
    order.reverse();
    let body = json!({ "categories": [{ "category_id": null, "channel_ids": order }] });
    let (status, body) = put_order(&app, &token, body).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(names(&body), ["c", "b", "a"]);
    assert_eq!(stored_order(&store).await, ["c", "b", "secret-staff", "a"]);
}

#[tokio::test]
async fn naming_a_channel_the_caller_cannot_see_is_refused_and_changes_nothing() {
    let (store, _guard, app, token) = setup().await;
    let hidden = store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .find(|c| c.name == "secret-staff")
        .unwrap()
        .id
        .to_string();
    let mut order = ids(&channels_of(&app, &token).await);
    order.push(hidden);
    let (status, _) = put_order(&app, &token, json!({ "channel_ids": order })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(stored_order(&store).await, ["a", "b", "secret-staff", "c"]);
}

#[tokio::test]
async fn a_partial_list_never_names_a_hidden_channel_as_missing() {
    let (store, _guard, app, token) = setup().await;
    let hidden = store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .find(|c| c.name == "secret-staff")
        .unwrap()
        .id
        .to_string();
    let first = ids(&channels_of(&app, &token).await)[..1].to_vec();
    let (status, body) = put_order(&app, &token, json!({ "channel_ids": first })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(!body.to_string().contains(&hidden), "{body}");
}
