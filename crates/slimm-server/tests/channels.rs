// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel rename and soft-delete: the MANAGE_CHANNELS gate, the
//! existence-not-observable behavior, idempotent delete, and the guard
//! against deleting the deployment's last channel.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token as register, request};

#[tokio::test]
async fn manager_can_rename_a_channel() {
    let (store, _guard) = support::new_store("slimm-channels-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    // A second channel so the rename target is never the deployment's last.
    store.create_channel("spare", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", channel.id),
            Some(&token),
            Some(json!({ "name": "renamed" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["name"], "renamed");
    assert_eq!(body["id"], channel.id.to_string());
}

#[tokio::test]
async fn renaming_without_manage_channels_is_forbidden() {
    let (store, _guard) = support::new_store("slimm-channels-test").await;
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
            Some(json!({ "name": "renamed" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// MANAGE_CHANNELS is checked at the deployment level, so a caller who lacks
/// it entirely cannot tell a real channel id from a fake one: both answer
/// Forbidden, never a distinguishing 404.
#[tokio::test]
async fn a_non_manager_cannot_distinguish_a_real_channel_from_a_fake_one_by_renaming() {
    let (store, _guard) = support::new_store("slimm-channels-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let real_status = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", channel.id),
            Some(&token),
            Some(json!({ "name": "renamed" })),
        ))
        .await
        .unwrap()
        .status();
    let fake_status = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", Uuid::now_v7()),
            Some(&token),
            Some(json!({ "name": "renamed" })),
        ))
        .await
        .unwrap()
        .status();

    assert_eq!(real_status, StatusCode::FORBIDDEN);
    assert_eq!(fake_status, real_status);
}

/// A caller who does hold MANAGE_CHANNELS gets an ordinary 404 for a channel
/// id that was never real: there is nothing left to hide from someone who
/// can already manage every real channel.
#[tokio::test]
async fn renaming_a_nonexistent_channel_by_a_manager_is_not_found() {
    let (store, _guard) = support::new_store("slimm-channels-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}", Uuid::now_v7()),
            Some(&token),
            Some(json!({ "name": "renamed" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn rename_validates_the_new_name() {
    let (store, _guard) = support::new_store("slimm-channels-test").await;
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
            Some(json!({ "name": "   " })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// A manager can delete a channel, and a second delete of the same channel
/// is not an error.
#[tokio::test]
async fn manager_can_delete_a_channel_idempotently() {
    let (store, _guard) = support::new_store("slimm-channels-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("doomed", "text").await.unwrap();
    store.create_channel("spare", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let uri = format!("/channels/{}", channel.id);
    for _ in 0..2 {
        let response = app
            .clone()
            .oneshot(request("DELETE", &uri, Some(&token), None))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/channels", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    let names: Vec<&str> = listed
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap())
        .collect();
    assert!(!names.contains(&"doomed"));
    assert!(names.contains(&"spare"));
}

/// The deployment's last live channel refuses deletion: with zero channels
/// left nobody has anywhere to land.
#[tokio::test]
async fn the_last_channel_cannot_be_deleted() {
    let (store, _guard) = support::new_store("slimm-channels-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("only", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);

    // It really is still there.
    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/channels", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(listed.as_array().unwrap().len(), 1);
}

/// A channel id that was never real is a plain 404 for a manager, distinct
/// from the 204 an already-deleted (but once real) channel gets.
#[tokio::test]
async fn deleting_a_channel_id_that_was_never_real_is_not_found() {
    let (store, _guard) = support::new_store("slimm-channels-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}", Uuid::now_v7()),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

/// `GET /channels` carries the caller's own effective permission bitmask on
/// every row, free from `visible_channels_with_permissions`'s already-computed
/// bitmask; `POST /channels` does not, since a create response has no one
/// caller's *channel* bitmask to embed - the channel is brand new.
#[tokio::test]
async fn listing_channels_includes_the_callers_own_permissions() {
    let (store, _guard) = support::new_store("slimm-channels-test").await;
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    store
        .set_role_overwrite(
            channel.id,
            everyone,
            Permissions::NONE,
            Permissions::SEND_MESSAGES,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/channels", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    let row = &listed.as_array().unwrap()[0];
    let bits = Permissions::from_bits(row["permissions"].as_i64().unwrap());
    assert!(bits.contains(Permissions::VIEW_CHANNEL));
    assert!(
        !bits.contains(Permissions::SEND_MESSAGES),
        "the channel overwrite denying SEND_MESSAGES must show up here"
    );

    let created = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/channels",
                Some(&token),
                Some(json!({ "name": "second" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert!(
        created.get("permissions").is_none(),
        "create has no one caller whose channel bitmask belongs on the response"
    );
}

#[tokio::test]
async fn deleting_without_manage_channels_is_forbidden() {
    let (store, _guard) = support::new_store("slimm-channels-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    store.create_channel("spare", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}
