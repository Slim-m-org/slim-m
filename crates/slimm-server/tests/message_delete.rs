// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Message deletion: author-or-manage authorization, idempotency, and the
//! fact that it cannot be used to probe for a message in a channel the
//! caller cannot see.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token_id as register, request};

/// Like `app`, but keeps a handle to the hub so a test can subscribe and
/// inspect what a route actually published.
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

/// The author can delete their own message, and a second delete of the same
/// message is not an error: it must stay idempotent for a client retrying
/// after a dropped response.
#[tokio::test]
async fn author_can_delete_their_own_message_and_it_is_idempotent() {
    let (store, _guard) = support::new_store("slimm-message-delete").await;
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
    let (token, _user) = register(&store, "alice").await;

    let sent = send(&app, &channel.id.to_string(), &token, "delete me").await;
    let message_id = sent["id"].as_str().unwrap().to_owned();
    let uri = format!("/channels/{}/messages/{message_id}", channel.id);

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
            .oneshot(request(
                "GET",
                &format!("/channels/{}/messages", channel.id),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        listed.as_array().unwrap().len(),
        0,
        "a deleted message must not appear in history"
    );
}

/// An ordinary member cannot delete someone else's message; a member with
/// MANAGE_MESSAGES can.
#[tokio::test]
async fn deleting_anothers_message_needs_manage_messages() {
    let (store, _guard) = support::new_store("slimm-message-delete").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let mods = store
        .create_role("mods", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());

    let (alice_token, _alice) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    let sent = send(
        &app,
        &channel.id.to_string(),
        &alice_token,
        "alice's message",
    )
    .await;
    let message_id = sent["id"].as_str().unwrap().to_owned();
    let uri = format!("/channels/{}/messages/{message_id}", channel.id);

    let forbidden = app
        .clone()
        .oneshot(request("DELETE", &uri, Some(&bob_token), None))
        .await
        .unwrap();
    assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);

    let bob = UserId(Uuid::parse_str(&bob_id).unwrap());
    store.assign_role(bob, mods).await.unwrap();
    let allowed = app
        .clone()
        .oneshot(request("DELETE", &uri, Some(&bob_token), None))
        .await
        .unwrap();
    assert_eq!(allowed.status(), StatusCode::NO_CONTENT);
}

/// Deleting a message in a channel the caller cannot view must answer exactly
/// as deleting a nonexistent message would, so the endpoint cannot be used to
/// probe for messages in a hidden channel.
#[tokio::test]
async fn deleting_in_a_hidden_channel_cannot_be_used_to_probe() {
    let (store, _guard) = support::new_store("slimm-message-delete").await;
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    let channel = store.create_channel("private", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let real = slimm_server::ids::MessageId::generate();
    let author = store.create_user("author", "Author").await.unwrap();
    store
        .send_message(NewMessage::plain(channel.id, author.id, real, "secret"))
        .await
        .unwrap();

    let hidden = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}/messages/{real}", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(hidden.status(), StatusCode::FORBIDDEN);
}

/// Deleting a message id that never existed, in a channel the caller can
/// view, is a plain 404.
#[tokio::test]
async fn deleting_an_unknown_message_in_a_visible_channel_is_not_found() {
    let (store, _guard) = support::new_store("slimm-message-delete").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let missing = Uuid::now_v7();
    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}/messages/{missing}", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

/// `send` calls `notify_reply` so a bystander watching the parent sees a
/// live reply count; delete has to mirror that or the count only moves once
/// the client happens to refetch. `channel.updated` proves the count itself
/// moved (thread_reply_count.rs); this proves the live signal fires too.
#[tokio::test]
async fn deleting_a_reply_in_a_thread_publishes_thread_updated() {
    let (store, _guard) = support::new_store("slimm-message-delete").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());
    let (token, _user) = register(&store, "alice").await;

    let parent = send(&app, &channel.id.to_string(), &token, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();

    let opened = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages/{parent_id}/thread", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(opened.status(), StatusCode::OK);
    let thread_id = json_body(opened).await["id"].as_str().unwrap().to_owned();

    let reply = send(&app, &thread_id, &token, "a reply").await;
    let reply_id = reply["id"].as_str().unwrap().to_owned();

    let mut rx = hub.subscribe();
    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{thread_id}/messages/{reply_id}"),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let mut reply_count = None;
    while let Ok(event) = rx.try_recv() {
        if let Event::ThreadUpdated {
            reply_count: count, ..
        } = event
        {
            reply_count = Some(count);
        }
    }
    assert_eq!(
        reply_count,
        Some(0),
        "deleting the only reply must publish ThreadUpdated with the count back at zero"
    );
}

/// `notify_reply` is a no-op outside a thread channel; an ordinary channel's
/// delete must not publish `ThreadUpdated` just because it happens to run
/// the same call.
#[tokio::test]
async fn deleting_in_an_ordinary_channel_publishes_no_thread_updated() {
    let (store, _guard) = support::new_store("slimm-message-delete").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());
    let (token, _user) = register(&store, "alice").await;

    let posted = send(&app, &channel.id.to_string(), &token, "not a reply").await;
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
            !matches!(event, Event::ThreadUpdated { .. }),
            "an ordinary channel's delete must not publish ThreadUpdated"
        );
    }
}

/// A retry delete of an already-gone message stays idempotent for both new
/// signals, not just the original `MessageDeleted`: the second call must
/// publish nothing at all, including no `ThreadUpdated`.
#[tokio::test]
async fn a_retry_delete_publishes_nothing_the_second_time() {
    let (store, _guard) = support::new_store("slimm-message-delete").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());
    let (token, _user) = register(&store, "alice").await;

    let parent = send(&app, &channel.id.to_string(), &token, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    let opened = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages/{parent_id}/thread", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    let thread_id = json_body(opened).await["id"].as_str().unwrap().to_owned();
    let reply = send(&app, &thread_id, &token, "a reply").await;
    let reply_id = reply["id"].as_str().unwrap().to_owned();
    let uri = format!("/channels/{thread_id}/messages/{reply_id}");

    let first = app
        .clone()
        .oneshot(request("DELETE", &uri, Some(&token), None))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::NO_CONTENT);

    let mut rx = hub.subscribe();
    let second = app
        .clone()
        .oneshot(request("DELETE", &uri, Some(&token), None))
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::NO_CONTENT);

    assert!(
        rx.try_recv().is_err(),
        "a retry of an already-deleted message must publish nothing at all"
    );
}
