// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A send whose request is dropped after its message committed.
//!
//! The server drops a handler when its connection closes or its request times
//! out. A retry of that id is not fresh, so it announces nothing: if the
//! dropped attempt had not fanned the message out, nothing ever would.

use std::future::Future;
use std::task::Poll;
use std::time::Duration;

use serde_json::json;
use slimm_server::hub::{Event, Hub, MessageEvent};
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
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
    // One poll at a time, so the request is dropped at its first wait after the commit.
    loop {
        let finished =
            std::future::poll_fn(|cx| Poll::Ready(send.as_mut().poll(cx).is_ready())).await;
        assert!(!finished, "the send finished before it could be dropped");
        if store.message_including_deleted(id).await.unwrap().is_some() {
            break;
        }
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
