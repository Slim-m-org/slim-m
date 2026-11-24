// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot's re-post of a member's words does not wake a member who blocked that member.

use std::time::Duration;

use slimm_server::hub::Hub;
use slimm_server::ids::{MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::push::{PushSender, SentMessage};
use slimm_server::store::NewMessage;

use crate::push_endpoints::harness::{
    SHORT_DEBOUNCE_MS, app, push_config, register_push, register_user, seeded_store,
    spawn_mock_relay, wait_until,
};

/// The pushes bob gets for a bot post that names him, optionally a re-post of carol, whom bob blocked.
async fn pushes_to_bob(reposts_carol: bool) -> usize {
    let (store, channel_id, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("push sender");
    let app = app(store.clone(), push.clone());
    let (_, alice_id) = register_user(&store, "alice").await;
    let (bob_token, bob_id) = register_user(&store, "bob").await;
    let (_, carol_id) = register_user(&store, "carol").await;
    register_push(&app, &bob_token, "bobs-token").await;
    let alice = UserId(alice_id.parse().unwrap());
    let bob = UserId(bob_id.parse().unwrap());
    let carol = UserId(carol_id.parse().unwrap());
    store.block_user(bob, carol).await.unwrap();
    let bot = store
        .create_bot("starbot", "Star", Permissions::NONE, alice)
        .await
        .expect("bot")
        .bot
        .user_id;
    let message_id = MessageId::generate();
    let sent = store
        .send_message(NewMessage::plain(
            channel_id,
            bot,
            message_id,
            "from carol: hi @bob",
        ))
        .await
        .unwrap();
    if reposts_carol {
        store.set_repost_author(message_id, carol).await.unwrap();
    }

    push.notify_message(
        store.clone(),
        SentMessage {
            channel_id,
            author_id: bot,
            message_id,
            seq: sent.message.seq,
            content: sent.message.content.clone(),
            presence: Hub::new().presence(),
            reply_ping: None,
            mass_authority: None,
        },
    );

    wait_until(|| mock.call_count() >= 1, Duration::from_millis(1500)).await;
    mock.all_messages().len()
}

#[tokio::test]
async fn a_repost_of_a_blocked_member_does_not_wake_the_blocker() {
    assert_eq!(pushes_to_bob(true).await, 0);
}

#[tokio::test]
async fn the_same_bot_post_without_a_repost_still_wakes_a_mentioned_member() {
    assert_eq!(pushes_to_bob(false).await, 1);
}
