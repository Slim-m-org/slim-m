// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A second factor that keeps being guessed at locks for longer each time, so grinding six
//! digits is not merely rate limited.
#![allow(dead_code)]

use axum::http::StatusCode;
use slimm_server::totp;

use crate::support;
use crate::totp_support;
use totp_support::{PASSWORD, app, enrol_and_confirm, login_for_challenge, member, now_ms, verify};

async fn locked_until(pool: &sqlx::SqlitePool) -> i64 {
    sqlx::query_scalar::<_, Option<i64>>("SELECT locked_until FROM user_totp_factors")
        .fetch_one(pool)
        .await
        .unwrap()
        .expect("the factor is locked")
}

#[tokio::test]
async fn each_lock_is_longer_than_the_one_before() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-totp-escalate").await;
    let auth = slimm_server::auth::Auth::new(2).unwrap();
    let first = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    enrol_and_confirm(&first, &token).await;
    let _ = PASSWORD;

    let mut waits = Vec::new();
    for run in 0..3 {
        let router = app(store.clone(), auth.clone());
        let challenge = login_for_challenge(&router, "ada").await;
        for _ in 0..totp::MAX_FAILURES {
            assert_eq!(
                verify(&router, &challenge, "000000").await.status(),
                StatusCode::BAD_REQUEST
            );
        }
        waits.push(locked_until(&pool).await - now_ms());
        sqlx::query("UPDATE user_totp_factors SET locked_until = 1")
            .execute(&pool)
            .await
            .unwrap();
        let _ = run;
    }

    assert!(
        waits[0] <= totp::lockout_ms(totp::MAX_FAILURES),
        "{waits:?}"
    );
    assert!(
        waits[1] > waits[0] * 2,
        "the second lock did not grow: {waits:?}"
    );
    assert!(
        waits[2] > waits[1] * 2,
        "the third lock did not grow: {waits:?}"
    );
}
