// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A retried poll send is answered as the retry it is, including after the
//! first one's message has been deleted.
//!
//! Its own binary rather than another test in `polls.rs`, which is already
//! past the file budget: this asks one question that the create, vote, close
//! and permission-matrix tests there do not, and it needs almost none of
//! their harness.
//!
//! The rule it pins belongs to the send path, not to polls. `store/messages.rs`
//! probes a tombstoned row on purpose, with a comment recording that filtering
//! deleted rows out let a retry fall through to an INSERT that hit the unique
//! id and surfaced as a 500. `sendPollMessage` is documented client-side as
//! "idempotent by [id] exactly like `SlimmApi.sendMessage`" and had its own
//! live-rows-only copy of that probe, so it had exactly the defect the comment
//! describes.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::MessageId;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body};

fn request(uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

/// Registers `username` and returns its access token and its own id.
async fn register(store: &Store, username: &str) -> (String, UserId) {
    let user = store.create_user(username, username).await.unwrap();
    let token = store
        .open_session(user.id, "device")
        .await
        .unwrap()
        .access_token;
    (token, user.id)
}

/// Without the fix this is a 500: the probe saw only live rows, so a retry
/// after the delete fell through to the INSERT and hit the unique id.
#[tokio::test]
async fn a_retry_after_the_message_was_deleted_is_still_idempotent() {
    let (store, _guard) = support::new_store("slimm-poll-idempotency-test").await;
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
    let (token, alice) = register(&store, "alice").await;

    let body = json!({
        "id": Uuid::now_v7().to_string(),
        "question": "tabs or spaces?",
        "options": ["tabs", "spaces"],
    });
    let uri = format!("/channels/{}/messages/polls", channel.id);

    let first = app
        .clone()
        .oneshot(request(&uri, &token, body.clone()))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    let message_id = json_body(first).await["id"].as_str().unwrap().to_owned();

    store
        .delete_message(MessageId(Uuid::parse_str(&message_id).unwrap()), alice)
        .await
        .unwrap();

    let retry = app.oneshot(request(&uri, &token, body)).await.unwrap();
    assert_eq!(
        retry.status(),
        StatusCode::OK,
        "a retry after the message was deleted must not surface as a 500",
    );
    assert_eq!(
        json_body(retry).await["id"].as_str().unwrap(),
        message_id,
        "and it must answer with the original message, not a new one",
    );
}

/// The scoping the fix must not have widened: a reused id belonging to
/// somebody else is still a conflict rather than a handed-over message.
#[tokio::test]
async fn a_reused_id_from_another_author_is_still_refused() {
    let (store, _guard) = support::new_store("slimm-poll-idempotency-test").await;
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
    let (alice, _) = register(&store, "alice").await;
    let (bob, _) = register(&store, "bob").await;

    let body = json!({
        "id": Uuid::now_v7().to_string(),
        "question": "tabs or spaces?",
        "options": ["tabs", "spaces"],
    });
    let uri = format!("/channels/{}/messages/polls", channel.id);

    let first = app
        .clone()
        .oneshot(request(&uri, &alice, body.clone()))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);

    let stolen = app.oneshot(request(&uri, &bob, body)).await.unwrap();
    assert_eq!(stolen.status(), StatusCode::CONFLICT);
}
