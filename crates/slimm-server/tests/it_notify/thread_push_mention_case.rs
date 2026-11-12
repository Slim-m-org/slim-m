// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A mention's username match has to agree with the client's own rendering,
//! or a chip that looks like it worked wakes nobody: `channel_screen.dart`
//! builds `knownUsernames` lowercased and `message_text.dart` matches a
//! typed `@name` against it lowercased too, so `Store::user_ids_for_usernames`
//! (`store/users.rs`) compares case-insensitively rather than mirroring
//! login's exact-case match.
//!
//! Split out of `thread_push_narrowing.rs`, which crossed the 500-line hard
//! limit adding these; both files exercise `push::message_recipients`
//! through the same `account`/`new_store` shape, just for different
//! properties of a thread reply's audience.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{DeviceId, MessageId, UserId};
use slimm_server::store::{NewMessage, PushRegistration, Store};

use crate::support;
use support::wake_recipients;

const KEY: [u8; 32] = [7u8; 32];

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

async fn account(store: &Store, username: &str) -> (UserId, DeviceId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let session = store.open_session(account.id, "phone").await.unwrap();
    (account.id, session.device_id)
}

/// A mention must match regardless of letter case, because the client's own
/// chip rendering already does: `channel_screen.dart` builds
/// `knownUsernames` lowercased and `message_text.dart` matches a typed
/// `@name` against it lowercased too, so `@Nick`, `@nick` and `@NICK` all
/// render as the same chip on screen. A server that matched exact case would
/// wake the stored-cased account only, leaving every other case a chip that
/// looks like it worked and silently never notifies anyone.
#[tokio::test]
async fn a_mention_wakes_its_target_regardless_of_letter_case() {
    let (store, _guard) = new_store("slimm-thread-push-mention-case").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let (nick, nick_device) = account(&store, "Nick").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    for (user, device, token) in [
        (alice, alice_device, "alice-token"),
        (bob, bob_device, "bob-token"),
        (nick, nick_device, "nick-token"),
    ] {
        store
            .register_push(
                user,
                device,
                PushRegistration {
                    platform: "ios",
                    push_token: token,
                    voip_push_token: None,
                    push_public_key: &KEY,
                    include_content: Some(false),
                    include_content_chosen: true,
                },
            )
            .await
            .unwrap();
    }

    let parent = store
        .send_message(NewMessage::plain(
            channel,
            alice,
            MessageId::generate(),
            "root",
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
            bob,
            MessageId::generate(),
            "first reply",
        ))
        .await
        .unwrap();

    for mention in ["@Nick", "@nick", "@NICK"] {
        let recipients = wake_recipients(&store, thread.id, bob, mention)
            .await
            .unwrap();
        assert!(
            recipients.contains(&nick),
            "{mention} must wake the account stored as \"Nick\", got {recipients:?}"
        );
    }
}

/// `nick` and `Nick` cannot both exist (migration 0095), so a mention can
/// never be ambiguous between two differently-cased accounts.
#[tokio::test]
async fn a_differently_cased_account_cannot_exist_beside_a_mentioned_one() {
    let (store, _guard) = new_store("slimm-thread-push-mention-both-cases").await;
    account(&store, "nick").await;
    let second = store
        .create_account("Nick", "Nick", "not-a-real-hash")
        .await;
    assert!(matches!(
        second,
        Err(slimm_server::store::RegisterError::UsernameTaken)
    ));
}
