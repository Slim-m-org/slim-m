// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Whose `MENTION_EVERYONE` decides how far an `@everyone` reaches when it is pushed: the
//! author's for what they wrote, and nobody's for text another party chose.

use std::time::Duration;

use slimm_server::hub::Hub;
use slimm_server::ids::{MessageId, Seq, UserId};
use slimm_server::notifications::NotificationPreference;
use slimm_server::permissions::Permissions;
use slimm_server::push::{PushSender, SentMessage};

use crate::push_endpoints::harness::{
    SHORT_DEBOUNCE_MS, app, push_config, register_push, register_user, seeded_store,
    spawn_mock_relay, wait_until,
};

/// The pushes bob gets for an `@everyone` that alice, who may mention everyone, is the author of.
async fn pushes_to_bob(mass_authority_is_alice: bool) -> Vec<String> {
    let (store, channel_id, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("push sender");
    let app = app(store.clone(), push.clone());
    let (_, alice_id) = register_user(&store, "alice").await;
    let (bob_token, bob_id) = register_user(&store, "bob").await;
    register_push(&app, &bob_token, "bobs-token").await;
    let (alice, bob) = (
        UserId(alice_id.parse().unwrap()),
        UserId(bob_id.parse().unwrap()),
    );
    let pingers = store
        .create_role("pingers", Permissions::MENTION_EVERYONE, false)
        .await
        .unwrap();
    store.assign_role(alice, pingers).await.unwrap();
    store
        .set_notification_preference(bob, NotificationPreference::Mentions)
        .await
        .unwrap();

    push.notify_message(
        store.clone(),
        SentMessage {
            channel_id,
            author_id: alice,
            message_id: MessageId::generate(),
            seq: Seq(1),
            content: "@everyone heads up".to_owned(),
            presence: Hub::new().presence(),
            reply_ping: None,
            mass_authority: mass_authority_is_alice.then_some(alice),
        },
    );

    wait_until(|| mock.call_count() >= 1, Duration::from_secs(2)).await;
    mock.all_messages()
        .iter()
        .map(|m| m["kind"].as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test]
async fn an_author_who_may_mention_everyone_wakes_a_mentions_only_member() {
    assert_eq!(pushes_to_bob(true).await, ["mention"]);
}

#[tokio::test]
async fn text_the_author_did_not_write_wakes_nobody_extra() {
    assert!(pushes_to_bob(false).await.is_empty());
}
