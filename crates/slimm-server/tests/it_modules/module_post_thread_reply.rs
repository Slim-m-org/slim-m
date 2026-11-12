// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module's `message.post` into a thread moves the thread's reply count live,
//! the way an ordinary send does.

use slimm_server::hub::{Event, MessageEvent};
use slimm_server::ids::MessageId;
use slimm_server::store::NewMessage;

use crate::support;
use support::module_world::{Install, post_request, world};
use support::wasm_fixtures::host_call_loop_wasm;

#[tokio::test]
async fn a_module_post_into_a_thread_publishes_a_reply_count_update() {
    let w = world("slimm-modcap-post-thread").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let root = MessageId::generate();
    w.store
        .send_message(NewMessage::plain(channel.id, w.user.id, root, "root"))
        .await
        .unwrap();
    let thread = w.store.open_thread(channel.id, root).await.unwrap().channel;
    let post = post_request(&thread.id.to_string(), "a reply from a module");
    w.install(Install {
        id: "replier",
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;

    let mut rx = w.hub.subscribe();
    let answer = w.answer_in("replier", Some(thread.id)).await;
    assert!(answer.starts_with("{'message_id':'"), "{answer}");

    let mut reply_count = None;
    while let Ok(event) = rx.try_recv() {
        if let Event::Message(MessageEvent::ThreadUpdated {
            reply_count: count, ..
        }) = event
        {
            reply_count = Some(count);
        }
    }
    assert_eq!(reply_count, Some(1));
}
