// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A channel someone can read but not post in (a bot feed, an announcement
//! channel) wakes them only for mentions, unless they chose otherwise for that
//! channel. Before this, every RSS item in a feed buzzed every member.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, DeviceId, UserId};
use slimm_server::notifications::NotificationPreference;
use slimm_server::permissions::Permissions;
use slimm_server::store::{PushRegistration, Store};

mod support;

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
    store
        .register_push(
            account.id,
            session.device_id,
            PushRegistration {
                platform: "ios",
                push_token: username,
                voip_push_token: None,
                push_public_key: &KEY,
                include_content: Some(false),
                include_content_chosen: true,
            },
        )
        .await
        .unwrap();
    (account.id, session.device_id)
}

/// alice posts; bob can read the channel but not send in it; carol can do both.
async fn feed(name: &str) -> (Store, support::TestDbGuard, ChannelId, [UserId; 3]) {
    let (store, guard) = new_store(name).await;
    let (alice, _) = account(&store, "alice").await;
    let (bob, _) = account(&store, "bob").await;
    let (carol, _) = account(&store, "carol").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    store
        .set_member_overwrite(channel, bob, Permissions::NONE, Permissions::SEND_MESSAGES)
        .await
        .unwrap();
    (store, guard, channel, [alice, bob, carol])
}

#[tokio::test]
async fn a_reader_who_cannot_post_is_not_woken_by_an_ordinary_post() {
    let (store, _guard, channel, [alice, bob, carol]) = feed("slimm-ro-push-plain").await;

    let woken = wake_recipients(&store, channel, alice, "new article")
        .await
        .unwrap();

    assert!(!woken.contains(&bob), "bob cannot post here, got {woken:?}");
    assert!(
        woken.contains(&carol),
        "carol can post, so her default stands"
    );
}

#[tokio::test]
async fn a_mention_still_wakes_a_reader_who_cannot_post() {
    let (store, _guard, channel, [alice, bob, _]) = feed("slimm-ro-push-mention").await;

    let woken = wake_recipients(&store, channel, alice, "hey @bob")
        .await
        .unwrap();

    assert!(woken.contains(&bob), "a mention is still addressed to bob");
}

#[tokio::test]
async fn choosing_everything_for_the_channel_wakes_a_reader_who_cannot_post() {
    let (store, _guard, channel, [alice, bob, _]) = feed("slimm-ro-push-optin").await;
    store
        .set_channel_notification_preference(bob, channel, NotificationPreference::Everything)
        .await
        .unwrap();

    let woken = wake_recipients(&store, channel, alice, "new article")
        .await
        .unwrap();

    assert!(woken.contains(&bob), "bob asked for every post here");
}
