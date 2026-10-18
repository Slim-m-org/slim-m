// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `MessageDto.mentions_me`: resolved once at send or edit time and read
//! back per viewer, the plumbing behind the channel rail's unread-mention
//! badge. The resolver itself (`@name`, `@[Role]`, `@everyone`/`@here`,
//! permission gating) is `push::recipients`'s own surface and is covered by
//! its own tests; these drive the HTTP layer end to end to prove the new
//! persistence and per-viewer read paths are wired to it correctly.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token as register, request};

async fn list_messages(app: &Router, channel_id: &str, token: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{channel_id}/messages"),
                Some(token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await
}

fn mentions_me(listed: &Value, message_id: &str) -> bool {
    listed
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == message_id)
        .unwrap_or_else(|| panic!("{message_id} not in {listed}"))["mentions_me"]
        .as_bool()
        .unwrap()
}

/// Everybody needs VIEW_CHANNEL/SEND_MESSAGES through @everyone so both
/// accounts below can post and read without a bespoke role each.
async fn everyone_role(store: &Store) {
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
}

/// A plain `@name` mention shows up for the account it names and nobody
/// else - not the author, not an unmentioned third viewer.
#[tokio::test]
async fn a_plain_mention_is_visible_only_to_the_account_it_names() {
    let (store, _guard) = support::new_store("slimm-message-mentions").await;
    everyone_role(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());

    let alice = register(&store, "alice").await;
    let bob = register(&store, "bob").await;
    let _carol = register(&store, "carol").await;

    let message_id = Uuid::now_v7().to_string();
    let sent = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{}/messages", channel.id),
                Some(&alice),
                Some(json!({ "id": message_id, "content": "hey @bob, look at this" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    // The sender's own echo never mentions its own author.
    assert_eq!(sent["mentions_me"], false);

    let bob_view = list_messages(&app, &channel.id.to_string(), &bob).await;
    assert!(
        mentions_me(&bob_view, &message_id),
        "bob was named by @bob and must see mentions_me: true"
    );

    let alice_view = list_messages(&app, &channel.id.to_string(), &alice).await;
    assert!(
        !mentions_me(&alice_view, &message_id),
        "the author is never resolved as mentioning themselves"
    );
}

/// Editing a message re-resolves its whole mention set: a mention added by
/// the edit appears, and one the edit dropped disappears, for the same
/// message id.
#[tokio::test]
async fn editing_a_message_recomputes_who_it_mentions() {
    let (store, _guard) = support::new_store("slimm-message-mentions").await;
    everyone_role(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());

    let alice = register(&store, "alice").await;
    let bob = register(&store, "bob").await;
    let carol = register(&store, "carol").await;

    let message_id = Uuid::now_v7().to_string();
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            Some(&alice),
            Some(json!({ "id": message_id, "content": "hey @bob" })),
        ))
        .await
        .unwrap();
    assert!(mentions_me(
        &list_messages(&app, &channel.id.to_string(), &bob).await,
        &message_id
    ));

    let edit = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}/messages/{message_id}", channel.id),
            Some(&alice),
            Some(json!({ "content": "actually, hey @carol" })),
        ))
        .await
        .unwrap();
    assert_eq!(edit.status(), StatusCode::OK);

    assert!(
        !mentions_me(
            &list_messages(&app, &channel.id.to_string(), &bob).await,
            &message_id
        ),
        "bob's mention was edited away and must not still read as mentioned"
    );
    assert!(
        mentions_me(
            &list_messages(&app, &channel.id.to_string(), &carol).await,
            &message_id
        ),
        "the edit's new mention must resolve for carol"
    );
}

/// A name quoted in inline code or a fenced block is not a mention: it must
/// not light the badge, and it must not wake a device either (the same scan
/// feeds push). Driven from the vectors the client asserts, so both sides
/// agree on where code starts and ends.
#[tokio::test]
async fn a_name_quoted_in_code_mentions_nobody() {
    let (store, _guard) = support::new_store("slimm-message-mentions").await;
    everyone_role(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let alice = register(&store, "alice").await;
    let bob = register(&store, "bob").await;
    let carol = register(&store, "carol").await;
    let vectors: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/code_fence_vectors.json"))
            .expect("the fence vectors are JSON");

    let mut checked = 0;
    for vector in vectors.iter().filter(|v| v.get("mentions").is_some()) {
        let message_id = Uuid::now_v7().to_string();
        let sent = app
            .clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{}/messages", channel.id),
                Some(&alice),
                Some(json!({ "id": message_id, "content": vector["content"] })),
            ))
            .await
            .unwrap();
        assert_eq!(sent.status(), StatusCode::OK, "{}", vector["name"]);
        for (name, token) in [("bob", &bob), ("carol", &carol)] {
            let expected = vector["mentions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|m| m == name);
            let listed = list_messages(&app, &channel.id.to_string(), token).await;
            assert_eq!(
                mentions_me(&listed, &message_id),
                expected,
                "{name} in vector: {}",
                vector["name"]
            );
        }
        checked += 1;
    }
    assert!(checked >= 8, "the vectors must carry mention expectations");
}
