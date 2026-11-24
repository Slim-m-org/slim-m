// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Batch lookups that bind a whole member or channel list must survive a list
//! longer than SQLite's bound-variable limit.

use crate::support;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;

const WIDE: usize = 40_000;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-wide-ids");
    let config = slimm_server::config::Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..slimm_server::config::Config::default()
    };
    let pool = slimm_server::db::connect(&config)
        .await
        .expect("connect + migrate");
    (Store::new(pool), guard)
}

fn wide_users(real: UserId) -> Vec<UserId> {
    let mut ids: Vec<UserId> = (0..WIDE).map(|_| UserId::generate()).collect();
    ids.push(real);
    ids
}

#[tokio::test]
async fn user_keyed_lookups_accept_more_ids_than_the_bind_limit() {
    let (store, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let users = wide_users(admin.id);

    let choices = store
        .channel_notification_choices(channel, None, &users)
        .await
        .unwrap();
    assert!(choices.contains_key(&admin.id));
    store.push_targets(&users).await.unwrap();
    let holders = store
        .holders_among(channel, &users, Permissions::VIEW_CHANNEL)
        .await
        .unwrap();
    assert!(holders.contains(&admin.id));
    assert!(
        store
            .timed_out_among_until(&users)
            .await
            .unwrap()
            .is_empty()
    );
    let presence = store.presence_visibility_many(&users).await.unwrap();
    assert!(presence.contains_key(&admin.id));
    store.roles_for_users(&users).await.unwrap();
    store.bot_user_ids(&users).await.unwrap();
    store
        .notification_schedules_for_users(&users)
        .await
        .unwrap();
    store
        .viewers_allowing_author_off_hours(&users, admin.id)
        .await
        .unwrap();
    store
        .viewers_allowing_channel_off_hours(&users, channel, None)
        .await
        .unwrap();
}

#[tokio::test]
async fn channel_keyed_lookups_accept_more_ids_than_the_bind_limit() {
    let (store, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let mut channels: Vec<ChannelId> = (0..WIDE).map(|_| ChannelId::generate()).collect();
    channels.push(channel);

    store.last_posted_in(&channels).await.unwrap();
    let query = store.fts_query_for("hello").await.unwrap().unwrap();
    store
        .search_call_transcripts(&channels, &query, None, 10)
        .await
        .unwrap();
}
