// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a forward carries, and what it refuses to carry.

use super::fixtures::*;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::hub::{Event, Hub, MessageEvent};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

/// The note and the forwarded original are separate fields. The whole point
/// of modelling this: provenance used to be composed into the sender's own
/// text, leaving nothing to render and nowhere to jump.
#[tokio::test]
async fn a_forward_keeps_the_note_and_the_original_apart() {
    let (store, _guard) = new_store().await;
    let (channel, token) = open_deployment(&store).await;
    let app = app(store.clone());
    let channel = channel.to_string();

    let original = send(&app, &channel, &token, "the original text").await;
    let response = post(
        &app,
        &channel,
        &token,
        forward_body("look at this", &original),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    let forward = json_body(response).await;

    assert_eq!(forward["content"], "look at this");
    assert_eq!(forward["forwarded"]["content"], "the original text");
    assert_eq!(forward["forwarded"]["message_id"], original["id"]);
    assert_eq!(forward["forwarded"]["channel_id"], channel);
    assert_eq!(forward["forwarded"]["author_display_name"], "Alice");
    assert_eq!(
        forward["forwarded"]["created_at"], original["created_at"],
        "the origin's own timestamp, not the forward's"
    );
}

/// A forward with nothing to add is a complete message, even though an empty
/// message that carries nothing else is still refused.
#[tokio::test]
async fn a_forward_needs_no_note_but_an_empty_message_still_does() {
    let (store, _guard) = new_store().await;
    let (channel, token) = open_deployment(&store).await;
    let app = app(store.clone());
    let channel = channel.to_string();

    let original = send(&app, &channel, &token, "the original text").await;
    let response = post(&app, &channel, &token, forward_body("", &original)).await;
    assert_eq!(response.status(), StatusCode::OK);
    let forward = json_body(response).await;
    assert_eq!(forward["content"], "");
    assert_eq!(forward["forwarded"]["content"], "the original text");

    let empty = post(
        &app,
        &channel,
        &token,
        json!({ "id": Uuid::now_v7().to_string(), "content": "   " }),
    )
    .await;
    assert_eq!(empty.status(), StatusCode::BAD_REQUEST);
}

/// The request carries an id and nothing else. Accepting an author or a body
/// from it would let anyone publish "X said Y" under another account's name
/// and face.
#[tokio::test]
async fn the_origin_is_read_from_the_server_not_the_request() {
    let (store, _guard) = new_store().await;
    let (channel, alice) = open_deployment(&store).await;
    let bob = register(&store, "bob", "Bob").await;
    let app = app(store.clone());
    let channel = channel.to_string();

    let original = send(&app, &channel, &alice, "alice wrote this").await;
    let mut body = forward_body("passing this on", &original);
    body["forwarded"] = json!({
        "content": "alice never wrote this",
        "author_display_name": "Someone Else",
    });
    let response = post(&app, &channel, &bob, body).await;
    assert_eq!(response.status(), StatusCode::OK);
    let forward = json_body(response).await;

    assert_eq!(forward["author_display_name"], "Bob", "sent by bob");
    assert_eq!(forward["forwarded"]["content"], "alice wrote this");
    assert_eq!(forward["forwarded"]["author_display_name"], "Alice");
}

/// A message in a channel the sender cannot see is refused exactly as one
/// that does not exist, so this cannot be used to probe for private messages.
#[tokio::test]
async fn forwarding_from_a_hidden_channel_cannot_be_used_to_probe() {
    let (store, _guard) = new_store().await;
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let open = store.create_channel("general", "text").await.unwrap();
    let alice = register(&store, "alice", "Alice").await;
    let app = app(store.clone());

    // Visible by default, then denied here: what makes it actually private.
    let hidden = store.create_channel("private", "text").await.unwrap();
    store
        .set_role_overwrite(
            hidden.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let author = store.create_user("author", "Author").await.unwrap();
    let secret = slimm_server::ids::MessageId::generate();
    store
        .send_message(slimm_server::store::NewMessage::plain(
            hidden.id,
            author.id,
            secret,
            "the secret",
        ))
        .await
        .unwrap();

    let refused = post(
        &app,
        &open.id.to_string(),
        &alice,
        json!({
            "id": Uuid::now_v7().to_string(),
            "content": "look",
            "forwarded_from_id": secret.to_string(),
        }),
    )
    .await;
    let unknown = post(
        &app,
        &open.id.to_string(),
        &alice,
        json!({
            "id": Uuid::now_v7().to_string(),
            "content": "look",
            "forwarded_from_id": Uuid::now_v7().to_string(),
        }),
    )
    .await;

    assert_eq!(refused.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        json_body(refused).await,
        json_body(unknown).await,
        "a hidden message and a nonexistent one must be indistinguishable"
    );
}

/// Forwarding copies the text, so forwarding a deleted message would
/// republish exactly what someone removed. This is the one place a forward
/// deliberately parts company with a reply, which may name a deleted parent.
#[tokio::test]
async fn a_deleted_message_cannot_be_forwarded() {
    let (store, _guard) = new_store().await;
    let (channel, token) = open_deployment(&store).await;
    let app = app(store.clone());
    let channel = channel.to_string();

    let original = send(&app, &channel, &token, "regrettable").await;
    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!(
                "/channels/{channel}/messages/{}",
                original["id"].as_str().unwrap()
            ),
            &token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let refused = post(&app, &channel, &token, forward_body("look", &original)).await;
    assert_eq!(refused.status(), StatusCode::BAD_REQUEST);
}

/// An ordinary message carries the key with a null, never omits it - the
/// convention `poll` and the thread fields already follow.
#[tokio::test]
async fn a_message_that_forwards_nothing_still_carries_the_key() {
    let (store, _guard) = new_store().await;
    let (channel, token) = open_deployment(&store).await;
    let app = app(store.clone());

    let plain = send(&app, &channel.to_string(), &token, "just a message").await;
    assert!(plain.get("forwarded").is_some(), "key present");
    assert!(plain["forwarded"].is_null());
}

/// The live frame has to be complete. Leaving the origin out is how an
/// attachment once arrived as a message that only grew its image on the next
/// sync, and a forward without its origin is a bare note.
#[tokio::test]
async fn the_live_frame_carries_the_origin() {
    let (store, _guard) = new_store().await;
    let (channel, token) = open_deployment(&store).await;
    let hub = Hub::new();
    let mut events = hub.subscribe();
    let app = app_with_hub(store.clone(), hub);
    let channel = channel.to_string();

    let original = send(&app, &channel, &token, "the original text").await;
    let _ = post(&app, &channel, &token, forward_body("look", &original)).await;

    let mut seen = None;
    while let Ok(event) = events.try_recv() {
        if let Event::Message(MessageEvent::Created { forwarded, .. }) = event {
            seen = Some(forwarded);
        }
    }
    let forwarded = seen
        .expect("a message.created was published")
        .expect("with its origin");
    assert_eq!(forwarded.origin.content, "the original text");
    assert_eq!(forwarded.author_display_name.as_deref(), Some("Alice"));
}

/// Editing the note must not cost the forward. The DTO's contract is that
/// `forwarded` is null only when a message forwards nothing, so an edit
/// route answering null for a message that does forward something is the
/// DTO lying - and a client that trusts it (this one writes the field
/// straight onto its local row) drops the origin until a full resync.
#[tokio::test]
async fn editing_a_forward_keeps_its_origin() {
    let (store, _guard) = new_store().await;
    let (channel, token) = open_deployment(&store).await;
    let app = app(store.clone());
    let channel = channel.to_string();

    let original = send(&app, &channel, &token, "the original text").await;
    let forward = json_body(
        post(
            &app,
            &channel,
            &token,
            forward_body("first note", &original),
        )
        .await,
    )
    .await;

    let edited = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!(
                "/channels/{channel}/messages/{}",
                forward["id"].as_str().unwrap()
            ),
            &token,
            Some(json!({ "content": "a better note" })),
        ))
        .await
        .unwrap();
    assert_eq!(edited.status(), StatusCode::OK);
    let body = json_body(edited).await;

    assert_eq!(body["content"], "a better note");
    assert_eq!(
        body["forwarded"]["content"], "the original text",
        "an edit changes the note, never what was forwarded"
    );
    assert_eq!(body["forwarded"]["author_display_name"], "Alice");
}

/// A note is the sender's own and they may take it back. An ordinary edit
/// refuses empty content because nothing would be left, but a forward still
/// carries the thing it was sent to carry.
#[tokio::test]
async fn the_note_on_a_forward_can_be_emptied_but_a_plain_message_cannot() {
    let (store, _guard) = new_store().await;
    let (channel, token) = open_deployment(&store).await;
    let app = app(store.clone());
    let channel = channel.to_string();

    let original = send(&app, &channel, &token, "the original text").await;
    let forward = json_body(
        post(
            &app,
            &channel,
            &token,
            forward_body("second thoughts", &original),
        )
        .await,
    )
    .await;

    let cleared = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!(
                "/channels/{channel}/messages/{}",
                forward["id"].as_str().unwrap()
            ),
            &token,
            Some(json!({ "content": "" })),
        ))
        .await
        .unwrap();
    assert_eq!(cleared.status(), StatusCode::OK);
    let body = json_body(cleared).await;
    assert_eq!(body["content"], "");
    assert_eq!(body["forwarded"]["content"], "the original text");

    let plain = json_body(
        post(
            &app,
            &channel,
            &token,
            json!({ "id": Uuid::now_v7().to_string(), "content": "words" }),
        )
        .await,
    )
    .await;
    let refused = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!(
                "/channels/{channel}/messages/{}",
                plain["id"].as_str().unwrap()
            ),
            &token,
            Some(json!({ "content": "  " })),
        ))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::BAD_REQUEST);
}

/// A retry of a send that already succeeded must return the stored message,
/// even when the thing it forwarded has since gone.
///
/// `reply_to_id` gets this right by being validated inside `send_message`,
/// after the idempotency short-circuit. `forwarded_from_id` was resolved in
/// the route before that check ever ran, so a client retrying an uncertain
/// send - the exact situation idempotency exists for - could be told its
/// message was invalid while the message sat in the channel.
#[tokio::test]
async fn retrying_a_forward_still_works_after_the_original_is_deleted() {
    let (store, _guard) = new_store().await;
    let (channel, token) = open_deployment(&store).await;
    let app = app(store.clone());
    let channel = channel.to_string();

    let original = send(&app, &channel, &token, "the original text").await;
    let send_id = Uuid::now_v7().to_string();
    let body = json!({
        "id": send_id,
        "content": "look at this",
        "forwarded_from_id": original["id"],
    });

    let first = post(&app, &channel, &token, body.clone()).await;
    assert_eq!(first.status(), StatusCode::OK);

    // The original goes before the client gets around to retrying.
    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!(
                "/channels/{channel}/messages/{}",
                original["id"].as_str().unwrap()
            ),
            &token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let retry = post(&app, &channel, &token, body).await;

    assert_eq!(
        retry.status(),
        StatusCode::OK,
        "the retry must return the stored message, not refuse it"
    );
    let retried = json_body(retry).await;
    assert_eq!(retried["id"], send_id);
    assert_eq!(retried["forwarded"]["removed"], true);
    assert_eq!(retried["forwarded"]["content"], "");
}
