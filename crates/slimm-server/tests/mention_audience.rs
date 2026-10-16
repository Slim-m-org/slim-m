// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A stored mention names only people who can see the channel: never the
//! author, never an account denied the channel, never a webhook principal
//! (issue 2058).

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::Hub;
use slimm_server::ids::UserId;
use slimm_server::mentions::mentioned_viewers;
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
