// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A post written by a bot or a webhook wakes a reader only when it mentions
//! them, unless they chose "everything" for that channel. A person's post is
//! unchanged. Before this, every post in a busy bot channel buzzed every member.

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

/// alice and bob are people with push; the channel is one both can post in.
async fn room(name: &str) -> (Store, support::TestDbGuard, ChannelId, [UserId; 2]) {
    let (store, guard) = new_store(name).await;
    let (alice, _) = account(&store, "alice").await;
    let (bob, _) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    (store, guard, channel, [alice, bob])
}

async fn bot(store: &Store, admin: UserId) -> UserId {
    let Ok(created) = store
        .create_bot("feedbot", "Feed", Permissions::NONE, admin)
        .await
    else {
        panic!("could not create the bot");
    };
    created.bot.user_id
}

#[tokio::test]
async fn an_unmentioning_bot_post_does_not_wake_a_member_on_the_default() {
    let (store, _guard, channel, [alice, bob]) = room("slimm-bot-push-plain").await;
    let bot = bot(&store, alice).await;

    let woken = wake_recipients(&store, channel, bot, "new article")
        .await
        .unwrap();

    assert!(!woken.contains(&bob), "got {woken:?}");
}

#[tokio::test]
async fn a_bot_post_that_mentions_a_member_wakes_them() {
    let (store, _guard, channel, [alice, bob]) = room("slimm-bot-push-mention").await;
    let bot = bot(&store, alice).await;

    let woken = wake_recipients(&store, channel, bot, "hey @bob")
        .await
        .unwrap();

    assert!(woken.contains(&bob), "got {woken:?}");
}

#[tokio::test]
async fn a_webhook_post_does_not_wake_a_member_on_the_default() {
    let (store, _guard, channel, [alice, bob]) = room("slimm-webhook-push-plain").await;
    let hook = store
        .create_webhook(channel, "ci", alice)
        .await
        .unwrap()
        .webhook
        .principal_id;

    let woken = wake_recipients(&store, channel, hook, "build passed")
        .await
        .unwrap();

    assert!(!woken.contains(&bob), "got {woken:?}");
}

#[tokio::test]
async fn a_person_post_still_wakes_a_member_on_the_default() {
    let (store, _guard, channel, [alice, bob]) = room("slimm-person-push-plain").await;

    let woken = wake_recipients(&store, channel, alice, "hello")
        .await
        .unwrap();

    assert!(woken.contains(&bob), "got {woken:?}");
}

#[tokio::test]
async fn choosing_everything_for_the_channel_wakes_a_member_for_a_bot_post() {
    let (store, _guard, channel, [alice, bob]) = room("slimm-bot-push-optin").await;
    let bot = bot(&store, alice).await;
    store
        .set_channel_notification_preference(bob, channel, NotificationPreference::Everything)
        .await
        .unwrap();

    let woken = wake_recipients(&store, channel, bot, "new article")
        .await
        .unwrap();

    assert!(woken.contains(&bob), "got {woken:?}");
}
