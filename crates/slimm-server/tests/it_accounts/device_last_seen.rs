// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `devices.last_seen_at` is written on sign-in, on a token refresh and on a
//! socket connect, and never per request, so the devices list can tell two
//! identical devices apart and show which one is in use.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{DeviceId, UserId};
use slimm_server::store::{RefreshOutcome, Store};
use sqlx::SqlitePool;

use crate::support;
async fn store() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-device-last-seen-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

async fn last_seen(s: &Store, user: UserId, device: DeviceId) -> Option<i64> {
    let devices = s.list_devices(user, device).await.unwrap();
    devices
        .into_iter()
        .find(|d| d.id == device)
        .unwrap()
        .last_seen_at
}

/// Pretends the device was last used long ago, so a later write is visible.
async fn age(pool: &SqlitePool, device: DeviceId) {
    sqlx::query("UPDATE devices SET last_seen_at = 1 WHERE id = ?")
        .bind(device)
        .execute(pool)
        .await
        .unwrap();
}

#[tokio::test]
async fn signing_in_stamps_the_device() {
    let (s, _pool, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let session = s.open_session(alice.id, "phone").await.unwrap();
    assert!(last_seen(&s, alice.id, session.device_id).await.unwrap() > 1);
}

#[tokio::test]
async fn a_token_refresh_stamps_the_device() {
    let (s, pool, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let session = s.open_session(alice.id, "phone").await.unwrap();
    age(&pool, session.device_id).await;

    let outcome = s.rotate_refresh(&session.refresh_token).await.unwrap();
    assert!(matches!(outcome, RefreshOutcome::Rotated(_)));
    assert!(last_seen(&s, alice.id, session.device_id).await.unwrap() > 1);
}

#[tokio::test]
async fn a_socket_connect_stamps_the_device_and_a_request_does_not() {
    let (s, pool, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let session = s.open_session(alice.id, "phone").await.unwrap();
    let ctx = s
        .authenticate(&session.access_token)
        .await
        .unwrap()
        .unwrap();
    age(&pool, session.device_id).await;

    let _ = s.authenticate(&session.access_token).await.unwrap();
    assert_eq!(
        last_seen(&s, alice.id, session.device_id).await,
        Some(1),
        "an authenticated request must not write"
    );

    let (ticket, _) = s.mint_ws_ticket(&ctx).await.unwrap();
    s.redeem_ws_ticket(&ticket).await.unwrap().unwrap();
    assert!(last_seen(&s, alice.id, session.device_id).await.unwrap() > 1);
}
