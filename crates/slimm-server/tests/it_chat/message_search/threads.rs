// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Thread replies are searched with the channel they hang off, from both the
//! per-channel route and `GET /search/messages`, and never from a thread whose
//! parent channel the caller cannot view or whose parent message is gone.
//! Only a client that asks with `include_threads=true` gets them: an older one
//! would open a thread hit as if the thread were a channel.

use serde_json::Value;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

use crate::message_search::fixtures::*;

async fn search(app: &axum::Router, token: &str, uri: &str) -> Vec<Value> {
    let body = json_body(
        app.clone()
            .oneshot(request("GET", uri, Some(token), None))
            .await
            .unwrap(),
    )
    .await;
    body.as_array().unwrap().clone()
}

/// Opens a thread on a fresh parent message in `channel` and plants `reply` in it.
async fn thread_with_reply(
    store: &Store,
    channel: ChannelId,
    reply: &str,
) -> (MessageId, ChannelId, UserId) {
    let author = store
        .create_account(&format!("u{}", MessageId::generate().0.simple()), "u", "x")
        .await
        .unwrap();
    let parent = store
        .send_message(NewMessage::plain(
            channel,
            author.id,
            MessageId::generate(),
            "parent",
        ))
        .await
        .unwrap();
    let thread = store
        .open_thread(channel, parent.message.id)
        .await
        .unwrap()
        .channel;
    store
        .send_message(NewMessage::plain(
            thread.id,
            author.id,
            MessageId::generate(),
            reply,
        ))
        .await
        .unwrap();
    (parent.message.id, thread.id, author.id)
}

#[tokio::test]
async fn a_thread_reply_is_found_from_its_channel_and_from_everywhere() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let general = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let (_, thread, _) = thread_with_reply(&store, general.id, "zeppelins overhead").await;

    for uri in [
        format!(
            "/channels/{}/messages/search?q=zeppelins&include_threads=true",
            general.id
        ),
        "/search/messages?q=zeppelins&include_threads=true".to_owned(),
    ] {
        let hits = search(&app, &token, &uri).await;
        assert_eq!(hits.len(), 1, "uri={uri}");
        assert_eq!(hits[0]["channel_id"], thread.to_string(), "uri={uri}");
        assert_eq!(
            hits[0]["thread_parent_channel_id"],
            general.id.to_string(),
            "uri={uri}"
        );
    }
}

#[tokio::test]
async fn a_hit_outside_a_thread_carries_no_thread_parent() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let general = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    send(&app, &general.id.to_string(), &token, "plain zeppelins").await;

    let hits = search(
        &app,
        &token,
        "/search/messages?q=zeppelins&include_threads=true",
    )
    .await;
    assert_eq!(hits.len(), 1);
    assert!(hits[0].get("thread_parent_channel_id").is_none());
}

#[tokio::test]
async fn a_thread_in_a_hidden_channel_or_under_a_deleted_parent_is_not_searched() {
    let (store, _guard) = new_store().await;
    let everyone = store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let lobby = store.create_channel("lobby", "text").await.unwrap();
    let vault = store.create_channel("vault", "text").await.unwrap();
    store
        .set_role_overwrite(
            vault.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    thread_with_reply(&store, vault.id, "zeppelins in the vault").await;
    let (parent, _, author) = thread_with_reply(&store, lobby.id, "zeppelins orphaned").await;
    store.delete_message(parent, author).await.unwrap();

    assert!(
        search(
            &app,
            &token,
            "/search/messages?q=zeppelins&include_threads=true"
        )
        .await
        .is_empty()
    );
    let lobby_uri = format!(
        "/channels/{}/messages/search?q=zeppelins&include_threads=true",
        lobby.id
    );
    assert!(search(&app, &token, &lobby_uri).await.is_empty());
}

#[tokio::test]
async fn a_client_that_does_not_ask_gets_no_thread_hits() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let general = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    thread_with_reply(&store, general.id, "zeppelins overhead").await;

    for uri in [
        format!("/channels/{}/messages/search?q=zeppelins", general.id),
        "/search/messages?q=zeppelins".to_owned(),
        "/search/messages?q=zeppelins&include_threads=false".to_owned(),
    ] {
        assert!(search(&app, &token, &uri).await.is_empty(), "uri={uri}");
    }
}
