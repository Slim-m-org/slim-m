// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `/notification-preferences/channels[/{channelId}]`: the HTTP surface over
//! `store/channel_notification_prefs.rs` - permission gating, input
//! validation, and the PUT/GET/DELETE round trip. `tests/channel_notification_prefs.rs`
//! covers the fan-out composition; this covers the route itself, the same
//! split `tests/channel_permissions.rs` draws for the sibling permissions
//! route.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_id_token as register, request_authed as request};

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

async fn general_channel_id(store: &Store) -> ChannelId {
    store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .next()
        .expect("bootstrap seeds a general channel")
        .id
}

/// The round trip a client actually does: set an override, list it back,
/// clear it, and see the list empty again.
#[tokio::test]
async fn set_list_and_clear_round_trip() {
    let (store, _guard) = new_store("slimm-chan-notif-http-round-trip").await;
    let app = app(store.clone());
    let (_id, token) = register(&store, "alice").await;
    let channel = general_channel_id(&store).await;

    let set = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/notification-preferences/channels/{channel}"),
            &token,
            Some(json!({ "preference": "mentions" })),
        ))
        .await
        .unwrap();
    assert_eq!(set.status(), StatusCode::OK);
    let body = json_body(set).await;
    assert_eq!(body["preference"], "mentions");
    assert_eq!(body["channel_id"], channel.to_string());

    let listed = app
        .clone()
        .oneshot(request(
            "GET",
            "/notification-preferences/channels",
            &token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(listed.status(), StatusCode::OK);
    let listed = json_body(listed).await;
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["channel_id"], channel.to_string());
    assert_eq!(listed[0]["preference"], "mentions");

    let cleared = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/notification-preferences/channels/{channel}"),
            &token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(cleared.status(), StatusCode::NO_CONTENT);

    let listed_after = app
        .oneshot(request(
            "GET",
            "/notification-preferences/channels",
            &token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(listed_after.status(), StatusCode::OK);
    let listed_after = json_body(listed_after).await;
    assert!(
        listed_after.as_array().unwrap().is_empty(),
        "a cleared override must not still be listed, got {listed_after}"
    );
}

/// `everything` is refused: having no row already means that, so writing it
/// would be a second spelling of the same answer.
#[tokio::test]
async fn setting_everything_is_refused() {
    let (store, _guard) = new_store("slimm-chan-notif-http-refuses-everything").await;
    let app = app(store.clone());
    let (_id, token) = register(&store, "alice").await;
    let channel = general_channel_id(&store).await;

    let response = app
        .oneshot(request(
            "PUT",
            &format!("/notification-preferences/channels/{channel}"),
            &token,
            Some(json!({ "preference": "everything" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// A nonsense preference string is refused the same way.
#[tokio::test]
async fn an_unrecognized_preference_is_refused() {
    let (store, _guard) = new_store("slimm-chan-notif-http-refuses-nonsense").await;
    let app = app(store.clone());
    let (_id, token) = register(&store, "alice").await;
    let channel = general_channel_id(&store).await;

    let response = app
        .oneshot(request(
            "PUT",
            &format!("/notification-preferences/channels/{channel}"),
            &token,
            Some(json!({ "preference": "silent" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// Setting an override on a channel the caller cannot view is refused, the
/// same VIEW_CHANNEL bar reading its messages already sets.
#[tokio::test]
async fn setting_a_preference_on_an_unviewable_channel_is_forbidden() {
    let (store, _guard) = new_store("slimm-chan-notif-http-forbidden").await;
    let app = app(store.clone());
    let (_admin, _admin_token) = register(&store, "alice").await;
    let (_member, member_token) = register(&store, "bob").await;
    let everyone = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .unwrap()
        .id;

    let hidden = store.create_channel("hidden", "text").await.unwrap();
    store
        .set_role_overwrite(
            hidden.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let response = app
        .oneshot(request(
            "PUT",
            &format!("/notification-preferences/channels/{}", hidden.id),
            &member_token,
            Some(json!({ "preference": "nothing" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// A fabricated channel id is refused the same 403 an unviewable real one
/// would be - never a 404, which would confirm one channel exists and the
/// other does not.
#[tokio::test]
async fn a_fabricated_channel_id_is_forbidden_not_not_found() {
    let (store, _guard) = new_store("slimm-chan-notif-http-fabricated").await;
    let app = app(store.clone());
    let (_id, token) = register(&store, "alice").await;
    let fabricated = ChannelId(Uuid::now_v7());

    let response = app
        .oneshot(request(
            "PUT",
            &format!("/notification-preferences/channels/{fabricated}"),
            &token,
            Some(json!({ "preference": "nothing" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// Clearing an override needs no VIEW_CHANNEL: it only ever touches the
/// caller's own row, keyed on their own id, so it must succeed even for a
/// channel the caller can no longer see - the one way back to the account
/// default must not itself be blocked by having lost view access.
#[tokio::test]
async fn clearing_survives_losing_view_access_to_the_channel() {
    let (store, _guard) = new_store("slimm-chan-notif-http-clear-after-lost-view").await;
    let app = app(store.clone());
    let (_admin, _admin_token) = register(&store, "alice").await;
    let (member, member_token) = register(&store, "bob").await;
    let channel = general_channel_id(&store).await;
    store
        .set_channel_notification_preference(
            member,
            channel,
            slimm_server::notifications::NotificationPreference::Nothing,
        )
        .await
        .unwrap();
    let everyone = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .unwrap()
        .id;
    store
        .set_role_overwrite(
            channel,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let cleared = app
        .oneshot(request(
            "DELETE",
            &format!("/notification-preferences/channels/{channel}"),
            &member_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(cleared.status(), StatusCode::NO_CONTENT);
}
