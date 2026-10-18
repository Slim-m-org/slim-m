// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A copy of the database alone must not yield a usable two-factor secret.
#![allow(dead_code)]

use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::data_key::DataKey;
use slimm_server::db;
use slimm_server::store::Store;

mod support;
mod totp_support;

use totp_support::{app, enrol_and_confirm, member};

struct Harness {
    pool: sqlx::SqlitePool,
    store: Store,
    auth: Auth,
    _guard: support::TestDbGuard,
}

async fn harness(key: DataKey) -> Harness {
    let (path, guard) = support::TestDbGuard::new("slimm-totp-at-rest");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.unwrap();
    Harness {
        store: Store::new(pool.clone()).with_data_key(key),
        pool,
        auth: Auth::new(2).unwrap(),
        _guard: guard,
    }
}

async fn stored_secret(pool: &sqlx::SqlitePool) -> String {
    sqlx::query_scalar("SELECT secret FROM user_totp_factors")
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn current_code(secret: &str) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    slimm_server::totp::code_at(secret, now).unwrap()
}

#[tokio::test]
async fn the_stored_secret_is_sealed_and_still_verifies() {
    let h = harness(DataKey::ephemeral()).await;
    let router = app(h.store.clone(), h.auth.clone());
    let (token, _) = member(&h.store, &h.auth, "alice").await;
    let user_id = h
        .store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    let (secret, _) = enrol_and_confirm(&router, &token).await;

    let stored = stored_secret(&h.pool).await;
    assert_ne!(stored, secret);
    assert!(
        !stored.contains(&secret),
        "the column holds the secret in the clear"
    );

    h.store
        .verify_totp_for_change(user_id, &current_code(&secret).await)
        .await
        .expect("a sealed secret still verifies a real code");
}

#[tokio::test]
async fn a_plaintext_row_is_sealed_on_startup_and_keeps_working() {
    let h = harness(DataKey::ephemeral()).await;
    let router = app(h.store.clone(), h.auth.clone());
    let (token, _) = member(&h.store, &h.auth, "alice").await;
    let user_id = h
        .store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    let (secret, _) = enrol_and_confirm(&router, &token).await;
    sqlx::query("UPDATE user_totp_factors SET secret = ?")
        .bind(&secret)
        .execute(&h.pool)
        .await
        .unwrap();
    assert_eq!(stored_secret(&h.pool).await, secret);

    h.store.seal_totp_secrets().await.unwrap();

    let stored = stored_secret(&h.pool).await;
    assert!(DataKey::is_sealed(&stored) && !stored.contains(&secret));
    h.store
        .verify_totp_for_change(user_id, &current_code(&secret).await)
        .await
        .expect("the migrated secret verifies");
}

#[tokio::test]
async fn another_key_cannot_use_a_copied_database() {
    let h = harness(DataKey::ephemeral()).await;
    let router = app(h.store.clone(), h.auth.clone());
    let (token, _) = member(&h.store, &h.auth, "alice").await;
    let user_id = h
        .store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    let (secret, _) = enrol_and_confirm(&router, &token).await;

    let stranger = Store::new(h.pool.clone()).with_data_key(DataKey::ephemeral());
    let attempt = stranger
        .verify_totp_for_change(user_id, &current_code(&secret).await)
        .await;
    assert!(
        attempt.is_err(),
        "a key the database was not sealed with must not verify"
    );
}
