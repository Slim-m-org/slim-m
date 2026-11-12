// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `list_devices` and the two push read paths must answer the same question
//! about whether a device is still live.
//!
//! They are three separate SQL predicates over the same tables, so nothing but
//! a test holds them together. Divergence is not symmetric and the bad
//! direction is push being the looser one: a device that drops off the
//! settings list while `push_targets` still returns it keeps notifying an
//! account it can no longer be used to open, and the owner has been left with
//! no handle to revoke it. The opposite direction is merely a dead row in a
//! list.
//!
//! Nothing revokes a session on refresh-token *expiry* - `sweep_expired_tokens`
//! deletes the row rather than revoking the session, and no other call site
//! does it either - so an idle device really does reach this state on its own
//! after `REFRESH_TTL_MS`, without anybody signing out.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::UserId;
use slimm_server::store::{PushRegistration, Store};
use sqlx::SqlitePool;

use crate::support;
const KEY: [u8; 32] = [0xAA; 32];

async fn store() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-device-liveness-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

/// Both answers for one user, as (listed, pushable).
async fn liveness(s: &Store, user: UserId, current: slimm_server::ids::DeviceId) -> (usize, usize) {
    let listed = s.list_devices(user, current).await.unwrap().len();
    let pushable = s.push_targets(&[user]).await.unwrap().len();
    (listed, pushable)
}

#[tokio::test]
async fn a_device_is_listed_exactly_when_it_is_pushable() {
    let (s, pool, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let session = s.open_session(alice.id, "phone").await.unwrap();
    s.register_push(
        alice.id,
        session.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "token",
            voip_push_token: None,
            push_public_key: &KEY,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();

    assert_eq!(
        liveness(&s, alice.id, session.device_id).await,
        (1, 1),
        "a freshly signed-in device with a registration is both listed and pushable"
    );

    // The state an idle phone reaches on its own after REFRESH_TTL_MS.
    sqlx::query("UPDATE refresh_tokens SET expires_at = 0")
        .execute(&pool)
        .await
        .unwrap();

    assert_eq!(
        liveness(&s, alice.id, session.device_id).await,
        (0, 0),
        "a device whose refresh token expired must stop being pushed to, not \
         merely stop being listed: hiding it while it still buzzes takes away \
         the only handle the owner had on it"
    );
}

#[tokio::test]
async fn revoking_a_session_agrees_across_both_reads() {
    let (s, _pool, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let session = s.open_session(alice.id, "phone").await.unwrap();
    s.register_push(
        alice.id,
        session.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "token",
            voip_push_token: None,
            push_public_key: &KEY,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();
    assert_eq!(liveness(&s, alice.id, session.device_id).await, (1, 1));

    s.remove_device(alice.id, session.device_id).await.unwrap();

    assert_eq!(
        liveness(&s, alice.id, session.device_id).await,
        (0, 0),
        "an explicitly removed device is gone from both"
    );
}

/// The fan-out's first step is `users_with_push_devices`, which decides whose
/// permissions get evaluated at all. It has its own copy of the predicate, so
/// a user whose only device is dead must not survive that step either.
#[tokio::test]
async fn a_user_whose_only_device_is_dead_is_not_a_push_candidate() {
    let (s, pool, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let session = s.open_session(alice.id, "phone").await.unwrap();
    s.register_push(
        alice.id,
        session.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "token",
            voip_push_token: None,
            push_public_key: &KEY,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();
    assert_eq!(s.users_with_push_devices().await.unwrap(), vec![alice.id]);

    sqlx::query("UPDATE refresh_tokens SET expires_at = 0")
        .execute(&pool)
        .await
        .unwrap();

    assert!(
        s.users_with_push_devices().await.unwrap().is_empty(),
        "a user with no live push-capable device is not worth evaluating \
         permissions for"
    );
}
