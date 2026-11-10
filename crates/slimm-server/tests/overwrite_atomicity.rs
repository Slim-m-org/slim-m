// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A single-target overwrite write and the un-sync of its channel land
//! together or not at all, the way the batch write already does.

use slimm_server::ids::{ChannelId, RoleId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use sqlx::SqlitePool;

mod support;

struct World {
    store: Store,
    pool: SqlitePool,
    channel: ChannelId,
    role: RoleId,
    member: UserId,
    _guard: support::TestDbGuard,
}

async fn world(prefix: &str) -> World {
    let (store, pool, guard) = support::new_store_with_pool(prefix).await;
    let owner = store
        .create_account("owner", "Owner", "hash")
        .await
        .unwrap();
    store.bootstrap_deployment(owner.id).await.unwrap();
    let member = store
        .create_account("member", "Member", "hash")
        .await
        .unwrap();
    let role = store
        .create_role("staff", Permissions::NONE, false)
        .await
        .unwrap();
    let channel = store.create_channel("secret", "text").await.unwrap().id;
    World {
        store,
        pool,
        channel,
        role,
        member: member.id,
        _guard: guard,
    }
}

async fn refuse_unsyncing(pool: &SqlitePool) {
    sqlx::query(
        "CREATE TRIGGER refuse_unsync BEFORE UPDATE OF permissions_synced ON channels
         BEGIN SELECT RAISE(ABORT, 'refused'); END",
    )
    .execute(pool)
    .await
    .unwrap();
}

#[tokio::test]
async fn a_role_overwrite_is_not_left_behind_when_unsyncing_the_channel_fails() {
    let w = world("slimm-overwrite-atomic-role").await;
    refuse_unsyncing(&w.pool).await;

    let result = w
        .store
        .set_role_overwrite(
            w.channel,
            w.role,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await;

    assert!(result.is_err());
    let left = w
        .store
        .overwrite_for(w.channel, "role", w.role.0)
        .await
        .unwrap();
    assert!(
        left.is_none(),
        "the deny must not outlive the failed request"
    );
}

#[tokio::test]
async fn a_member_overwrite_is_not_left_behind_when_unsyncing_the_channel_fails() {
    let w = world("slimm-overwrite-atomic-member").await;
    refuse_unsyncing(&w.pool).await;

    let result = w
        .store
        .set_member_overwrite(
            w.channel,
            w.member,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await;

    assert!(result.is_err());
    let left = w
        .store
        .overwrite_for(w.channel, "member", w.member.0)
        .await
        .unwrap();
    assert!(left.is_none());
}

#[tokio::test]
async fn an_overwrite_is_not_cleared_when_unsyncing_the_channel_fails() {
    let w = world("slimm-overwrite-atomic-delete").await;
    w.store
        .set_role_overwrite(
            w.channel,
            w.role,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    refuse_unsyncing(&w.pool).await;

    assert!(
        w.store
            .delete_role_overwrite(w.channel, w.role)
            .await
            .is_err()
    );
    let kept = w
        .store
        .overwrite_for(w.channel, "role", w.role.0)
        .await
        .unwrap();
    assert!(kept.is_some(), "the deny must still be in force");
}
