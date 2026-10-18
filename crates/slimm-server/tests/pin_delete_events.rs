// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `Event::MessageUnpinned` on the message-delete path (MOD12).
//!
//! Split out of `pins.rs` to stay under the file budget: the DB trigger in
//! `0009_pins.sql` already drops a pinned message's row the instant it is
//! soft-deleted (see `pins.rs`'s own `deleting_a_pinned_message_removes_its_pin`),
//! but nothing told a live client that until this. Without the event a client
//! watching the channel keeps showing a pin that has already gone until it
//! happens to refetch.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{json_body, register_token_id as register, request};

/// Keeps a handle to the hub so a test can subscribe and inspect what the
/// route actually published, the same shape `dm_open_publishes_no_event.rs`
/// uses.
fn app_with_hub(store: Store, hub: Hub) -> Router {
    support::app::builder(store).hub(hub).router()
}

async fn send(app: &Router, channel_id: &str, token: &str, content: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel_id}/messages"),
                Some(token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await
}

fn pin_uri(channel_id: &str, message_id: &str) -> String {
    format!("/channels/{channel_id}/messages/{message_id}/pin")
}

/// The DB trigger already drops the pin row the instant a pinned message is
/// soft-deleted (see `pins.rs`'s `deleting_a_pinned_message_removes_its_pin`);
/// a live client watching the channel only learns that if the delete handler
/// tells it, or it keeps showing the pin until it happens to refetch.
#[tokio::test]
async fn deleting_a_pinned_message_publishes_message_unpinned() {
    let (store, _guard) = support::new_store("slimm-pin-delete-events").await;
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
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());
    let (token, _user) = register(&store, "alice").await;

    let posted = send(&app, &channel.id.to_string(), &token, "pin then delete").await;
    let message_id = posted["id"].as_str().unwrap().to_owned();

    let pinned = app
        .clone()
        .oneshot(request(
            "PUT",
            &pin_uri(&channel.id.to_string(), &message_id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(pinned.status(), StatusCode::NO_CONTENT);

    let mut rx = hub.subscribe();
    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}/messages/{message_id}", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let target = MessageId(Uuid::parse_str(&message_id).unwrap());
    let mut unpinned = false;
    while let Ok(event) = rx.try_recv() {
        if matches!(event, Event::MessageUnpinned { message_id, .. } if message_id == target) {
            unpinned = true;
        }
    }
    assert!(
        unpinned,
        "deleting a pinned message must publish MessageUnpinned"
    );
}

/// The mirror of the test above: a message that was never pinned must not
/// make its delete claim it was, or a client would go hunting for a pin
/// that never existed.
#[tokio::test]
async fn deleting_an_unpinned_message_publishes_no_message_unpinned() {
    let (store, _guard) = support::new_store("slimm-pin-delete-events").await;
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
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());
    let (token, _user) = register(&store, "alice").await;

    let posted = send(&app, &channel.id.to_string(), &token, "never pinned").await;
    let message_id = posted["id"].as_str().unwrap().to_owned();

    let mut rx = hub.subscribe();
    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}/messages/{message_id}", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    while let Ok(event) = rx.try_recv() {
        assert!(
            !matches!(event, Event::MessageUnpinned { .. }),
            "an unpinned message's delete must not publish MessageUnpinned"
        );
    }
}
