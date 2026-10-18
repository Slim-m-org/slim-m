// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reactions: idempotency, the permission gate, and the fact that reacting
//! cannot be used to discover a message in a channel you cannot read.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use slimm_server::store::NewMessage;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token as register, request};

/// Reacting twice with the same emoji must leave one reaction, because a double
/// tap on a slow connection is the normal case rather than an edge case.
#[tokio::test]
async fn reacting_twice_is_idempotent() {
    let (store, _guard) = support::new_store("slimm-reactions").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ADD_REACTIONS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let message_id = Uuid::now_v7().to_string();
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            Some(&token),
            Some(json!({ "id": message_id, "content": "react to me" })),
        ))
        .await
        .unwrap();

    let uri = format!("/messages/{message_id}/reactions/%F0%9F%91%8D");
    for _ in 0..3 {
        let response = app
            .clone()
            .oneshot(request("PUT", &uri, Some(&token), None))
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
    let reactions = &listed.as_array().unwrap()[0]["reactions"];
    assert_eq!(reactions.as_array().unwrap().len(), 1);
    assert_eq!(reactions[0]["count"], 1, "three taps must count once");
    assert_eq!(reactions[0]["reacted"], true);

    // And removing is idempotent in the same way.
    for _ in 0..2 {
        let response = app
            .clone()
            .oneshot(request("DELETE", &uri, Some(&token), None))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }
}

/// Reacting must not confirm that a message exists in a channel the caller
/// cannot see: an unreadable message and a missing one answer identically.
#[tokio::test]
async fn reacting_cannot_probe_for_messages_you_cannot_see() {
    let (store, _guard) = support::new_store("slimm-reactions").await;
    // @everyone can send and react but NOT view, so the author can post
    // through a role of their own while a stranger sees nothing.
    store
        .create_role("everyone", Permissions::ADD_REACTIONS, true)
        .await
        .unwrap();
    let channel = store.create_channel("private", "text").await.unwrap();
    let app = app(store.clone());

    let stranger = register(&store, "stranger").await;

    // A message id that certainly does not exist.
    let missing = Uuid::now_v7().to_string();
    let missing_status = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/messages/{missing}/reactions/%F0%9F%91%8D"),
            Some(&stranger),
            None,
        ))
        .await
        .unwrap()
        .status();

    // A real message in a channel the stranger cannot view.
    let author = store.create_user("author", "Author").await.unwrap();
    let real = slimm_server::ids::MessageId::generate();
    store
        .send_message(NewMessage::plain(channel.id, author.id, real, "secret"))
        .await
        .unwrap();
    let hidden_status = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/messages/{real}/reactions/%F0%9F%91%8D"),
            Some(&stranger),
            None,
        ))
        .await
        .unwrap()
        .status();

    assert_eq!(missing_status, StatusCode::NOT_FOUND);
    assert_eq!(
        hidden_status, missing_status,
        "a hidden message must answer exactly as a missing one, or reacting is a probe"
    );
}
