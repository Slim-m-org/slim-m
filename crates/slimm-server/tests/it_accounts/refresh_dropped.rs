// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A refresh token whose rows went with its device or account is refused for
//! that reason, not as one this server never issued, until the sweep would
//! have taken its rows anyway.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::{RefreshDenial, RefreshOutcome, Store};
use sqlx::SqlitePool;

use crate::support;

async fn store() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-refresh-dropped-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

async fn denial(store: &Store, refresh_token: &str) -> Option<RefreshDenial> {
    match store.rotate_refresh(refresh_token).await.unwrap() {
        RefreshOutcome::Denied(denial) => Some(denial),
        RefreshOutcome::Rotated(_) | RefreshOutcome::Reused(_) => None,
    }
}

#[tokio::test]
async fn a_token_from_a_removed_device_is_refused_as_device_removed() {
    let (store, _pool, _guard) = store().await;
    let user = store.create_user("alice", "Alice").await.unwrap();
    let laptop = store.open_session(user.id, "laptop").await.unwrap();
    let phone = store.open_session(user.id, "phone").await.unwrap();

    store
        .remove_device(user.id, laptop.device_id)
        .await
        .unwrap()
        .expect("alice's own device");

    assert_eq!(
        denial(&store, &laptop.refresh_token).await,
        Some(RefreshDenial::DeviceRemoved)
    );
    assert!(
        matches!(
            store.rotate_refresh(&phone.refresh_token).await.unwrap(),
            RefreshOutcome::Rotated(_)
        ),
        "the other device keeps signing in"
    );
}

#[tokio::test]
async fn a_token_of_a_deleted_account_is_refused_as_account_deleted() {
    let (store, _pool, _guard) = store().await;
    let user = store.create_user("alice", "Alice").await.unwrap();
    let laptop = store.open_session(user.id, "laptop").await.unwrap();

    store.delete_account(user.id).await.unwrap();

    assert_eq!(
        denial(&store, &laptop.refresh_token).await,
        Some(RefreshDenial::AccountDeleted)
    );
}

#[tokio::test]
async fn a_token_never_issued_is_refused_as_unknown() {
    let (store, _pool, _guard) = store().await;
    assert_eq!(
        denial(&store, "never-issued").await,
        Some(RefreshDenial::Unknown)
    );
}

#[tokio::test]
async fn a_dropped_hash_is_swept_when_its_row_would_have_been() {
    const DAY_MS: i64 = 24 * 60 * 60 * 1000;
    let (store, pool, _guard) = store().await;
    let user = store.create_user("alice", "Alice").await.unwrap();
    let laptop = store.open_session(user.id, "laptop").await.unwrap();
    store
        .remove_device(user.id, laptop.device_id)
        .await
        .unwrap()
        .expect("alice's own device");

    let kept = store.sweep_expired_tokens().await.unwrap();
    assert_eq!(kept.dropped_refresh_tokens, 0, "still inside its lifetime");

    sqlx::query("UPDATE dropped_refresh_tokens SET expires_at = expires_at - ?")
        .bind(120 * DAY_MS)
        .execute(&pool)
        .await
        .unwrap();
    let swept = store.sweep_expired_tokens().await.unwrap();
    assert_eq!(swept.dropped_refresh_tokens, 1);
    assert_eq!(
        denial(&store, &laptop.refresh_token).await,
        Some(RefreshDenial::Unknown)
    );
}
