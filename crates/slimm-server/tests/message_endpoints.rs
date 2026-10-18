// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! HTTP integration tests for the message endpoints, covering the happy path,
//! idempotency, validation, and the authorization matrix.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::auth::Auth;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{json_body, register_token_id as register, request};

/// Builds a router sharing `store`, so roles and channels created directly on the
/// store are visible to the handlers.
fn app(store: Store) -> Router {
    let auth = Auth::new(2).expect("auth service");
    support::app::builder(store).auth(auth).router()
}

#[tokio::test]
async fn send_list_and_edit_happy_path() {
    let (store, _guard) = support::new_store("slimm-msg-test").await;
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

    let uri = format!("/channels/{}/messages", channel.id);
    let message_id = Uuid::now_v7().to_string();

    // Send.
    let sent = app
        .clone()
        .oneshot(request(
            "POST",
            &uri,
            Some(&token),
            Some(json!({ "id": message_id, "content": "hello" })),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
    let sent = json_body(sent).await;
    assert_eq!(sent["seq"], 1);
    assert_eq!(sent["content"], "hello");

    // List returns it.
    let listed = app
        .clone()
        .oneshot(request("GET", &uri, Some(&token), None))
        .await
        .unwrap();
    assert_eq!(listed.status(), StatusCode::OK);
    let listed = json_body(listed).await;
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["id"], message_id);

    // Edit own message.
    let edit_uri = format!("/channels/{}/messages/{}", channel.id, message_id);
    let edited = app
        .clone()
        .oneshot(request(
            "PATCH",
            &edit_uri,
            Some(&token),
            Some(json!({ "content": "hello again" })),
        ))
        .await
        .unwrap();
    assert_eq!(edited.status(), StatusCode::OK);
    let edited = json_body(edited).await;
    assert_eq!(edited["content"], "hello again");
    assert!(edited["edited_at"].is_i64());
}

#[tokio::test]
async fn send_is_idempotent_over_http() {
    let (store, _guard) = support::new_store("slimm-msg-test").await;
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

    let uri = format!("/channels/{}/messages", channel.id);
    let message_id = Uuid::now_v7().to_string();
    let send = |content: &str| {
        request(
            "POST",
            &uri,
            Some(&token),
            Some(json!({ "id": message_id, "content": content })),
        )
    };

    let first = json_body(app.clone().oneshot(send("original")).await.unwrap()).await;
    // A retry with the same id returns the stored message, not the new content.
    let retry = json_body(app.clone().oneshot(send("changed")).await.unwrap()).await;
    assert_eq!(first["seq"], retry["seq"]);
    assert_eq!(retry["content"], "original");

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", &uri, Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(listed.as_array().unwrap().len(), 1, "no duplicate row");
}

#[tokio::test]
async fn send_id_is_scoped_to_channel_and_author() {
    let (store, _guard) = support::new_store("slimm-msg-test").await;
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
    let (alice, _alice_id) = register(&store, "alice").await;
    let (bob, _bob_id) = register(&store, "bob").await;

    let shared_id = Uuid::now_v7().to_string();

    // Alice posts the id into channel A.
    let sent = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages", channel_a.id),
            Some(&alice),
            Some(json!({ "id": shared_id, "content": "alice in A" })),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);

    // Reusing the same id in a different channel is a conflict; it must never
    // return channel A's message (the IDOR this guards against).
    let cross_channel = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages", channel_b.id),
            Some(&alice),
            Some(json!({ "id": shared_id, "content": "alice in B" })),
        ))
        .await
        .unwrap();
    assert_eq!(cross_channel.status(), StatusCode::CONFLICT);

    // Another author reusing the id in the same channel is also a conflict.
    let cross_author = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages", channel_a.id),
            Some(&bob),
            Some(json!({ "id": shared_id, "content": "bob in A" })),
        ))
        .await
        .unwrap();
    assert_eq!(cross_author.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn permissions_are_enforced() {
    // @everyone can view but not send.
    let (store, _guard) = support::new_store("slimm-msg-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let uri = format!("/channels/{}/messages", channel.id);

    // View is allowed.
    let listed = app
        .clone()
        .oneshot(request("GET", &uri, Some(&token), None))
        .await
        .unwrap();
    assert_eq!(listed.status(), StatusCode::OK);

    // Sending is forbidden.
    let sent = app
        .clone()
        .oneshot(request(
            "POST",
            &uri,
            Some(&token),
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": "nope" })),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn no_view_permission_hides_the_channel() {
    let (store, _guard) = support::new_store("slimm-msg-test").await;
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let listed = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{}/messages", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(listed.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn editing_another_users_message_needs_manage() {
    let (store, _guard) = support::new_store("slimm-msg-test").await;
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

    // Alice sends a message.
    let uri = format!("/channels/{}/messages", channel.id);
    let message_id = Uuid::now_v7().to_string();
    let sent = app
        .clone()
        .oneshot(request(
            "POST",
            &uri,
            Some(&alice_token),
            Some(json!({ "id": message_id, "content": "alice's message" })),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);

    let edit_uri = format!("/channels/{}/messages/{}", channel.id, message_id);
    let edit = |token: &str| {
        request(
            "PATCH",
            &edit_uri,
            Some(token),
            Some(json!({ "content": "edited by bob" })),
        )
    };

    // Bob, an ordinary member, cannot edit Alice's message.
    let forbidden = app.clone().oneshot(edit(&bob_token)).await.unwrap();
    assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);

    // Give Bob the mods role; now he can.
    let bob = UserId(Uuid::parse_str(&bob_id).unwrap());
    store.assign_role(bob, mods).await.unwrap();
    let allowed = app.clone().oneshot(edit(&bob_token)).await.unwrap();
    assert_eq!(allowed.status(), StatusCode::OK);
}

#[tokio::test]
async fn validation_and_missing_resources() {
    let (store, _guard) = support::new_store("slimm-msg-test").await;
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

    let uri = format!("/channels/{}/messages", channel.id);

    // Empty content is a 400.
    let empty = app
        .clone()
        .oneshot(request(
            "POST",
            &uri,
            Some(&token),
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": "   " })),
        ))
        .await
        .unwrap();
    assert_eq!(empty.status(), StatusCode::BAD_REQUEST);

    // A nonexistent channel grants no permissions, so posting to one is refused
    // exactly like one the caller cannot see: existence stays unobservable.
    let missing = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages", Uuid::now_v7()),
            Some(&token),
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": "hi" })),
        ))
        .await
        .unwrap();
    assert_eq!(missing.status(), StatusCode::FORBIDDEN);

    // No bearer token is a 401.
    let anon = app
        .clone()
        .oneshot(request("GET", &uri, None, None))
        .await
        .unwrap();
    assert_eq!(anon.status(), StatusCode::UNAUTHORIZED);
}

/// A channel renders sender names, so the message payload has to carry one.
/// Without it the client has only an opaque user id to show, which is exactly
/// what it used to display.
///
/// The read path has its own query, so it is asserted separately: an echo that
/// names the author while a reload shows a bare id would look like the bug had
/// been fixed until the app restarted.
#[tokio::test]
async fn a_message_carries_its_author_display_name() {
    let (store, _guard) = support::new_store("slimm-msg-test").await;
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

    let uri = format!("/channels/{}/messages", channel.id);
    let sent = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &uri,
                Some(&token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": "who said this" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        sent["author_display_name"], "alice",
        "the echoed message must name its author, not just its id"
    );

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", &uri, Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        listed.as_array().unwrap()[0]["author_display_name"],
        "alice"
    );
}

/// Send and delete both charged the Write bucket; edit did not, so one account
/// could re-run the FTS5 re-index trigger as fast as it could send requests.
/// The Write budget is a burst of 30, so a run well past that must start being
/// refused.
#[tokio::test]
async fn editing_is_rate_limited_like_the_other_writes() {
    let (store, _guard) = support::new_store("slimm-msg-test").await;
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

    let message_id = Uuid::now_v7().to_string();
    let sent = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            Some(&token),
            Some(json!({ "id": message_id, "content": "original" })),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);

    let uri = format!("/channels/{}/messages/{message_id}", channel.id);
    let mut statuses = Vec::new();
    for i in 0..60 {
        let response = app
            .clone()
            .oneshot(request(
                "PATCH",
                &uri,
                Some(&token),
                Some(json!({ "content": format!("edit {i}") })),
            ))
            .await
            .unwrap();
        statuses.push(response.status());
    }

    assert!(
        statuses.contains(&StatusCode::OK),
        "the first edits inside the burst are answered: {statuses:?}"
    );
    assert!(
        statuses.contains(&StatusCode::TOO_MANY_REQUESTS),
        "a sustained edit flood must be refused: {statuses:?}"
    );
}
