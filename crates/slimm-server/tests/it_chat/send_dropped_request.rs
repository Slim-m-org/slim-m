// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A message write whose request is dropped after it committed.
//!
//! The server drops a handler when its connection closes or its request times
//! out. A retry finds the write already done, so it announces nothing: if the
//! dropped attempt had not fanned it out, nothing ever would.

use std::future::Future;
use std::task::Poll;
use std::time::Duration;

use serde_json::{Value, json};
use slimm_server::hub::{Event, Hub, MessageEvent};
use slimm_server::ids::{MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::NewMessage;
use tokio::sync::broadcast::Receiver;
use tower::ServiceExt;

use crate::support;
use support::app::request_authed as request;

/// How many `message.created` events for `id` arrive before the hub goes quiet.
async fn created_events(events: &mut Receiver<Event>, id: MessageId) -> usize {
    let mut seen = 0;
    while let Ok(Ok(event)) = tokio::time::timeout(Duration::from_millis(500), events.recv()).await
    {
        if matches!(&event, Event::Message(MessageEvent::Created { message, .. }) if message.id == id)
        {
            seen += 1;
        }
    }
    seen
}

#[tokio::test]
async fn a_send_dropped_after_it_committed_is_still_announced_once() {
    let (store, _guard) = support::new_store("slimm-send-dropped").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let hub = Hub::new();
    let app = support::app::builder(store.clone())
        .hub(hub.clone())
        .router();
    let user = store.create_user("alice", "Alice").await.unwrap();
    let token = store
        .open_session(user.id, "dev")
        .await
        .unwrap()
        .access_token;
    let channel = store.create_channel("general", "text").await.unwrap();
    let mut events = hub.subscribe();

    let id = MessageId::generate();
    let uri = format!("/channels/{}/messages", channel.id);
    let body = json!({ "id": id.to_string(), "content": "hello" });
    let mut send = Box::pin(
        app.clone()
            .oneshot(request("POST", &uri, &token, Some(body.clone()))),
    );
    // One poll at a time, so the request is dropped at its first wait after the commit; see drop_after_commit.
    loop {
        let finished =
            std::future::poll_fn(|cx| Poll::Ready(send.as_mut().poll(cx).is_ready())).await;
        if store.message_including_deleted(id).await.unwrap().is_some() {
            break;
        }
        assert!(!finished, "the send finished without committing");
    }
    drop(send);

    // The sender's client saw no answer, so it sends the same id again.
    let retry = app
        .oneshot(request("POST", &uri, &token, Some(body)))
        .await
        .unwrap();
    assert!(retry.status().is_success());

    assert_eq!(
        created_events(&mut events, id).await,
        1,
        "a stored message nobody was told about, or told about twice"
    );
}

#[tokio::test]
async fn an_edit_dropped_after_it_committed_is_still_announced_once() {
    let (store, _guard) = support::new_store("slimm-edit-dropped").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let hub = Hub::new();
    let app = support::app::builder(store.clone())
        .hub(hub.clone())
        .router();
    let user = store.create_user("alice", "Alice").await.unwrap();
    let token = store
        .open_session(user.id, "dev")
        .await
        .unwrap()
        .access_token;
    let channel = store.create_channel("general", "text").await.unwrap();
    let id = MessageId::generate();
    store
        .send_message(NewMessage::plain(channel.id, user.id, id, "hello"))
        .await
        .unwrap();
    let mut events = hub.subscribe();

    let uri = format!("/channels/{}/messages/{id}", channel.id);
    let body = json!({ "content": "hello again" });
    let mut edit =
        Box::pin(
            app.clone()
                .oneshot(request("PATCH", &uri, &token, Some(body.clone()))),
        );
    loop {
        let finished =
            std::future::poll_fn(|cx| Poll::Ready(edit.as_mut().poll(cx).is_ready())).await;
        let stored = store.message(id).await.unwrap().unwrap();
        if stored.content == "hello again" {
            break;
        }
        assert!(!finished, "the edit finished without committing");
    }
    drop(edit);

    // The same text again changes nothing, so the retry has nothing to announce.
    let retry = app
        .oneshot(request("PATCH", &uri, &token, Some(body)))
        .await
        .unwrap();
    assert!(retry.status().is_success());

    let mut announced = 0;
    while let Ok(Ok(event)) = tokio::time::timeout(Duration::from_millis(500), events.recv()).await
    {
        if matches!(&event, Event::Message(MessageEvent::Edited { message, .. }) if message.id == id)
        {
            announced += 1;
        }
    }
    assert_eq!(announced, 1, "an edit the others never saw");
}

/// A reaction has no op stream to catch it up, so a dropped attempt's frame is the only signal anybody gets.
#[tokio::test]
async fn a_reaction_dropped_after_it_committed_is_still_announced() {
    let (store, _guard) = support::new_store("slimm-reaction-dropped").await;
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
    let hub = Hub::new();
    let app = support::app::builder(store.clone())
        .hub(hub.clone())
        .router();
    let user = store.create_user("alice", "Alice").await.unwrap();
    let token = store
        .open_session(user.id, "dev")
        .await
        .unwrap()
        .access_token;
    let channel = store.create_channel("general", "text").await.unwrap();
    let id = MessageId::generate();
    store
        .send_message(NewMessage::plain(channel.id, user.id, id, "hello"))
        .await
        .unwrap();
    let mut events = hub.subscribe();

    let uri = format!("/messages/{id}/reactions/%F0%9F%91%8D");
    let mut react = Box::pin(app.oneshot(request("PUT", &uri, &token, None)));
    loop {
        let finished =
            std::future::poll_fn(|cx| Poll::Ready(react.as_mut().poll(cx).is_ready())).await;
        if !store.reaction_reactors(id).await.unwrap().is_empty() {
            break;
        }
        assert!(!finished, "the reaction finished without committing");
    }
    drop(react);

    let mut announced = 0;
    while let Ok(Ok(event)) = tokio::time::timeout(Duration::from_millis(500), events.recv()).await
    {
        if matches!(&event, Event::Message(MessageEvent::ReactionsChanged { message_id, .. }) if *message_id == id)
        {
            announced += 1;
        }
    }
    assert_eq!(announced, 1, "a stored reaction nobody else was told about");
}

/// Polls `request` one step at a time and drops it at its first wait once `committed` holds.
///
/// The work runs on a task of its own, so it can finish while `committed` is being read; that only fails if nothing was stored.
async fn drop_after_commit<R, C>(request: R, mut committed: impl FnMut() -> C)
where
    R: Future,
    C: Future<Output = bool>,
{
    let mut request = Box::pin(request);
    loop {
        let finished =
            std::future::poll_fn(|cx| Poll::Ready(request.as_mut().poll(cx).is_ready())).await;
        if committed().await {
            break;
        }
        assert!(!finished, "the request finished without committing");
    }
}

/// A bulk delete's own frames are the only way a live client learns the purge happened.
async fn a_bulk_delete_dropped_after_it_committed(
    path: &str,
    body: impl Fn(UserId, &[MessageId]) -> Value,
) {
    let (store, _guard) = support::new_store("slimm-bulk-delete-dropped").await;
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
    let hub = Hub::new();
    let app = support::app::builder(store.clone())
        .hub(hub.clone())
        .router();
    let user = store.create_user("alice", "Alice").await.unwrap();
    let token = store
        .open_session(user.id, "dev")
        .await
        .unwrap()
        .access_token;
    let channel = store.create_channel("general", "text").await.unwrap();
    let ids = [MessageId::generate(), MessageId::generate()];
    for id in ids {
        store
            .send_message(NewMessage::plain(channel.id, user.id, id, "spam"))
            .await
            .unwrap();
    }
    let mut events = hub.subscribe();

    let uri = format!("/channels/{}/messages/{path}", channel.id);
    let request = app.oneshot(request("POST", &uri, &token, Some(body(user.id, &ids))));
    drop_after_commit(request, || {
        let store = store.clone();
        async move { store.message(ids[1]).await.unwrap().is_none() }
    })
    .await;

    let mut announced = Vec::new();
    while let Ok(Ok(event)) = tokio::time::timeout(Duration::from_millis(500), events.recv()).await
    {
        if let Event::Message(MessageEvent::Deleted { message_id, .. }) = event {
            announced.push(message_id);
        }
    }
    announced.sort_by_key(ToString::to_string);
    let mut expected = ids.to_vec();
    expected.sort_by_key(ToString::to_string);
    assert_eq!(announced, expected, "a purge the others never saw");
}

#[tokio::test]
async fn a_bulk_delete_dropped_after_it_committed_is_still_announced() {
    a_bulk_delete_dropped_after_it_committed("bulk-delete", |_, ids| {
        let ids: Vec<String> = ids.iter().map(ToString::to_string).collect();
        json!({ "message_ids": ids })
    })
    .await;
}

#[tokio::test]
async fn a_bulk_delete_by_author_dropped_after_it_committed_is_still_announced() {
    a_bulk_delete_dropped_after_it_committed(
        "bulk-delete-by-author",
        |author, _| json!({ "author_id": author.to_string(), "window_minutes": 15 }),
    )
    .await;
}
