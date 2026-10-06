// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A webhook holds no roles, not even `@everyone`, so every batched permission
//! read must agree with the per-user check about it.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;

mod support;

async fn store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-perm-webhook-batch");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

#[tokio::test]
async fn viewers_among_never_counts_a_webhook_as_a_viewer() {
    let (s, _guard) = store().await;
    s.create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let admin = s.create_user("admin", "Admin").await.unwrap();
    let member = s.create_user("member", "Member").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    let hook = s
        .create_webhook(channel.id, "alerts", admin.id)
        .await
        .unwrap()
        .webhook
        .principal_id;

    let single = s
        .has_permission(hook, channel.id, Permissions::VIEW_CHANNEL)
        .await
        .unwrap();
    assert!(!single, "the per-user check gives a webhook nothing");

    let batched = s
        .viewers_among(channel.id, &[member.id, hook])
        .await
        .unwrap();
    assert_eq!(batched, vec![member.id], "the batched check must agree");
}
