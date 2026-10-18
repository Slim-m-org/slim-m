// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! HTTP integration tests for `reply_to_id`: the write-time validation that
//! keeps a reply's parent in the same channel, and that the id rides the
//! wire unchanged through send, list and a parent's own later deletion.
//!
//! There is deliberately no server-side "preview" of the parent to test
//! here: the wire carries only the id (see `Message::reply_to_id`'s doc
//! comment), and a client resolves the rest by looking that id up like any
//! other message. That resolution, and its blocked/deleted-parent honesty,
//! is client-side and tested in `client/packages/app`.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::auth::Auth;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{json_body, register_token as register, request_authed as request};

fn app(store: Store) -> Router {
    let auth = Auth::new(2).expect("auth service");
    support::app::builder(store).auth(auth).router()
}

#[tokio::test]
async fn a_reply_carries_its_parent_id_through_send_and_list() {
    let (store, _guard) = support::new_store("slimm-reply-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let uri = format!("/channels/{}/messages", channel.id);

    let parent = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &uri,
                &token,
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": "original" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert!(parent["reply_to_id"].is_null());
    let parent_id = parent["id"].as_str().unwrap().to_owned();

    let reply = app
        .clone()
        .oneshot(request(
            "POST",
            &uri,
            &token,
            Some(json!({
                "id": Uuid::now_v7().to_string(),
                "content": "a reply",
                "reply_to_id": parent_id,
            })),
        ))
        .await
        .unwrap();
    assert_eq!(reply.status(), StatusCode::OK);
    let reply = json_body(reply).await;
    assert_eq!(reply["reply_to_id"], parent_id);

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", &uri, &token, None))
            .await
            .unwrap(),
    )
    .await;
    let rows = listed.as_array().unwrap();
    // Newest first: the reply is index 0, the parent index 1.
    assert_eq!(rows[0]["reply_to_id"], parent_id);
    assert!(rows[1]["reply_to_id"].is_null());
}

#[tokio::test]
async fn replying_to_a_message_in_another_channel_is_refused() {
    let (store, _guard) = support::new_store("slimm-reply-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel_a = store.create_channel("a", "text").await.unwrap();
    let channel_b = store.create_channel("b", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let parent = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{}/messages", channel_a.id),
                &token,
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": "in A" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();

    let cross_channel_reply = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages", channel_b.id),
            &token,
            Some(json!({
                "id": Uuid::now_v7().to_string(),
                "content": "reply from B to A",
                "reply_to_id": parent_id,
            })),
        ))
        .await
        .unwrap();
    assert_eq!(cross_channel_reply.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn replying_to_a_nonexistent_message_is_refused() {
    let (store, _guard) = support::new_store("slimm-reply-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
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
            "POST",
            &format!("/channels/{}/messages", channel.id),
            &token,
            Some(json!({
                "id": Uuid::now_v7().to_string(),
                "content": "reply to nothing",
                "reply_to_id": Uuid::now_v7().to_string(),
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// A reply's own row never loses its `reply_to_id` when the parent is later
/// deleted: nothing here reconciles the reference, by design, and the client
/// is what renders the parent as unavailable by resolving the id fresh.
#[tokio::test]
async fn a_reply_survives_its_parent_being_deleted() {
    let (store, _guard) = support::new_store("slimm-reply-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::MANAGE_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let uri = format!("/channels/{}/messages", channel.id);

    let parent = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &uri,
                &token,
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": "will be deleted" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();

    let reply = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &uri,
                &token,
                Some(json!({
                    "id": Uuid::now_v7().to_string(),
                    "content": "a reply to it",
                    "reply_to_id": parent_id,
                })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let reply_id = reply["id"].as_str().unwrap().to_owned();

    let delete = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}/messages/{parent_id}", channel.id),
            &token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(delete.status(), StatusCode::NO_CONTENT);

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", &uri, &token, None))
            .await
            .unwrap(),
    )
    .await;
    let rows = listed.as_array().unwrap();
    assert_eq!(
        rows.len(),
        1,
        "the deleted parent is gone, the reply is not"
    );
    assert_eq!(rows[0]["id"], reply_id);
    assert_eq!(
        rows[0]["reply_to_id"], parent_id,
        "the reply still names its now-deleted parent"
    );
}

/// A reply may itself be replied to; nothing here treats a chain specially.
#[tokio::test]
async fn a_reply_to_a_reply_is_allowed() {
    let (store, _guard) = support::new_store("slimm-reply-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let uri = format!("/channels/{}/messages", channel.id);

    let root = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &uri,
                &token,
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": "root" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let root_id = root["id"].as_str().unwrap().to_owned();

    let middle = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &uri,
                &token,
                Some(json!({
                    "id": Uuid::now_v7().to_string(),
                    "content": "middle",
                    "reply_to_id": root_id,
                })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let middle_id = middle["id"].as_str().unwrap().to_owned();

    let leaf = app
        .clone()
        .oneshot(request(
            "POST",
            &uri,
            &token,
            Some(json!({
                "id": Uuid::now_v7().to_string(),
                "content": "leaf",
                "reply_to_id": middle_id,
            })),
        ))
        .await
        .unwrap();
    assert_eq!(leaf.status(), StatusCode::OK);
    let leaf = json_body(leaf).await;
    assert_eq!(leaf["reply_to_id"], middle_id);
}
