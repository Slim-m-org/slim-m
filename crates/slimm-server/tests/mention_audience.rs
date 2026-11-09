// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A stored mention names only people who can see the channel: never the
//! author, never an account denied the channel, never a webhook principal
//! (issue 2058).

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::Hub;
use slimm_server::ids::UserId;
use slimm_server::mentions::{mentioned_viewers, mentioned_viewers_under};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use sqlx::SqlitePool;

mod support;

async fn store() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-mention-audience");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

async fn account(s: &Store, name: &str) -> UserId {
    s.create_account(name, name, "x").await.unwrap().id
}

#[tokio::test]
async fn a_plain_mention_stores_only_viewers_other_than_the_author() {
    let (s, pool, _guard) = store().await;
    s.create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let viewers = s
        .create_role("viewers", Permissions::VIEW_CHANNEL, false)
        .await
        .unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    let (ann, bob, carol, hook) = (
        account(&s, "ann").await,
        account(&s, "bob").await,
        account(&s, "carol").await,
        account(&s, "hook").await,
    );
    for id in [ann, bob, hook] {
        s.assign_role(id, viewers).await.unwrap();
    }
    sqlx::query("UPDATE users SET is_webhook = 1 WHERE id = ?")
        .bind(hook)
        .execute(&pool)
        .await
        .unwrap();

    let presence = Hub::new().presence();
    let mentioned = mentioned_viewers(&s, channel.id, ann, "@ann @bob @carol @hook", &presence)
        .await
        .unwrap();

    assert_eq!(mentioned, vec![bob], "ann={ann} carol={carol} hook={hook}");
}

#[tokio::test]
async fn a_message_naming_nobody_mentions_nobody() {
    let (s, _pool, _guard) = store().await;
    let channel = s.create_channel("general", "text").await.unwrap();
    let ann = account(&s, "ann").await;
    let presence = Hub::new().presence();
    let mentioned = mentioned_viewers(&s, channel.id, ann, "just talking", &presence)
        .await
        .unwrap();
    assert!(mentioned.is_empty());
}

/// `ann` and `dan` may mention everyone; `bob` and `carol` only read the channel.
async fn pingers_and_readers() -> (
    Store,
    slimm_server::ids::ChannelId,
    [UserId; 4],
    support::TestDbGuard,
) {
    let (s, _pool, guard) = store().await;
    s.create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let viewers = s
        .create_role("viewers", Permissions::VIEW_CHANNEL, false)
        .await
        .unwrap();
    let pingers = s
        .create_role("pingers", Permissions::MENTION_EVERYONE, false)
        .await
        .unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    let ids = [
        account(&s, "ann").await,
        account(&s, "bob").await,
        account(&s, "carol").await,
        account(&s, "dan").await,
    ];
    for id in ids {
        s.assign_role(id, viewers).await.unwrap();
    }
    for id in [ids[0], ids[3]] {
        s.assign_role(id, pingers).await.unwrap();
    }
    (s, channel.id, ids, guard)
}

#[tokio::test]
async fn the_authors_own_reach_decides_a_mass_mention_by_default() {
    let (s, channel, [ann, bob, carol, dan], _guard) = pingers_and_readers().await;
    let presence = Hub::new().presence();

    let mut by_ann = mentioned_viewers(&s, channel, ann, "@everyone", &presence)
        .await
        .unwrap();
    let by_bob = mentioned_viewers(&s, channel, bob, "@everyone", &presence)
        .await
        .unwrap();

    by_ann.sort();
    let mut expected = vec![bob, carol, dan];
    expected.sort();
    assert_eq!(by_ann, expected);
    assert!(by_bob.is_empty());
}

#[tokio::test]
async fn another_principals_reach_decides_when_the_author_did_not_write_the_text() {
    let (s, channel, [ann, bob, carol, dan], _guard) = pingers_and_readers().await;
    let presence = Hub::new().presence();

    let none = mentioned_viewers_under(&s, channel, (ann, None), "@everyone", &presence)
        .await
        .unwrap();
    let by_reader = mentioned_viewers_under(&s, channel, (ann, Some(bob)), "@everyone", &presence)
        .await
        .unwrap();
    let mut by_dan = mentioned_viewers_under(&s, channel, (ann, Some(dan)), "@everyone", &presence)
        .await
        .unwrap();

    assert!(none.is_empty() && by_reader.is_empty());
    by_dan.sort();
    let mut expected = vec![bob, carol, dan];
    expected.sort();
    assert_eq!(by_dan, expected);
}

#[tokio::test]
async fn naming_a_person_needs_no_reach_at_all() {
    let (s, channel, [ann, bob, _, _], _guard) = pingers_and_readers().await;
    let presence = Hub::new().presence();

    let named = mentioned_viewers_under(&s, channel, (ann, None), "@everyone @bob", &presence)
        .await
        .unwrap();

    assert_eq!(named, vec![bob]);
}
