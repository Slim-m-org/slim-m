// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Forwarding something that was itself forwarded.

use super::fixtures::*;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use uuid::Uuid;

/// Passing on something that was itself passed on has to carry the original,
/// not the last person's note about it. A forward's own `content` is that
/// note and is usually empty, so snapshotting it would hand the next reader
/// an empty card attributed to the middleman.
#[tokio::test]
async fn forwarding_a_forward_carries_the_first_original() {
    let (store, _guard) = new_store().await;
    let (channel, alice) = open_deployment(&store).await;
    let bob = register(&store, "bob", "Bob").await;
    let app = app(store.clone());
    let channel = channel.to_string();

    let original = send(&app, &channel, &alice, "the original text").await;
    let first = json_body(post(&app, &channel, &alice, forward_body("", &original)).await).await;

    let second =
        json_body(post(&app, &channel, &bob, forward_body("passing it on", &first)).await).await;

    assert_eq!(second["content"], "passing it on");
    assert_eq!(
        second["forwarded"]["content"], "the original text",
        "the first original, not the middleman's empty note"
    );
    assert_eq!(second["forwarded"]["author_display_name"], "Alice");
    assert_eq!(
        second["forwarded"]["message_id"], original["id"],
        "and it points at the original itself, so a jump lands there"
    );
}

/// Access is checked against the message you named, never the origin it
/// resolves to. Somebody forwards you something out of a channel you cannot
/// see; you can still pass that on, because what you are relaying is the
/// forward in front of you, which somebody with access already released.
/// Checking the origin instead would make a forward unforwardable by exactly
/// the people it was sent to.
#[tokio::test]
async fn a_forward_out_of_a_hidden_channel_can_still_be_passed_on() {
    let (store, _guard) = new_store().await;
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
    let open = store.create_channel("general", "text").await.unwrap();
    let hidden = store.create_channel("private", "text").await.unwrap();
    let alice = register(&store, "alice", "Alice").await;
    let app = app(store.clone());

    // Written before the deny, then hidden: alice never had access to it.
    let author = store.create_user("author", "Author").await.unwrap();
    let secret = slimm_server::ids::MessageId::generate();
    store
        .send_message(slimm_server::store::NewMessage::plain(
            hidden.id,
            author.id,
            secret,
            "from behind the door",
        ))
        .await
        .unwrap();
    let relay_id = slimm_server::ids::MessageId::generate();
    let source = store.forward_source(secret).await.unwrap().unwrap();
    store
        .send_message(slimm_server::store::NewMessage {
            channel_id: open.id,
            author_id: author.id,
            id: relay_id,
            content: "",
            attachment_ids: &[],
            spoiler_ids: &[],
            reply_to_id: None,
            forward: Some(source.origin),
        })
        .await
        .unwrap();
    store
        .set_role_overwrite(
            hidden.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let response = post(
        &app,
        &open.id.to_string(),
        &alice,
        json!({
            "id": Uuid::now_v7().to_string(),
            "content": "onwards",
            "forwarded_from_id": relay_id.to_string(),
        }),
    )
    .await;

    assert_eq!(response.status(), StatusCode::OK);
    let forward = json_body(response).await;
    assert_eq!(forward["forwarded"]["content"], "from behind the door");
}
