// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot token's `last_used_at` is a cosmetic stamp: when it cannot be written
//! (another writer holds the lock past the busy timeout) the bot's valid
//! request still goes through, and when it can, the stamp is recorded.

use axum::http::StatusCode;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

mod support;

use support::app::{app, register_id, request};

async fn stamp(pool: &sqlx::SqlitePool) -> Option<i64> {
    sqlx::query_scalar("SELECT last_used_at FROM bot_tokens")
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn a_bot_request_is_stamped_when_the_write_succeeds() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-bot-stamp-ok").await;
    let admin = register_id(&store, "root").await;
    let bot = store
        .create_bot("helper", "Helper", Permissions::NONE, admin)
        .await
        .unwrap();
    assert!(stamp(&pool).await.is_none());

    assert!(store.authenticate_bot(&bot.token).await.unwrap().is_some());

    assert!(stamp(&pool).await.is_some());
}

#[tokio::test]
async fn a_bot_request_succeeds_when_its_stamp_cannot_be_written() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-bot-stamp-fails").await;
    let admin = register_id(&store, "root").await;
    let bot = store
        .create_bot("helper", "Helper", Permissions::NONE, admin)
        .await
        .unwrap();
    let router = app(store.clone());
    sqlx::query(
        "CREATE TRIGGER boom BEFORE UPDATE ON bot_tokens \
         BEGIN SELECT RAISE(ABORT, 'database is locked'); END",
    )
    .execute(&pool)
    .await
    .unwrap();

    let response = router
        .oneshot(request("GET", "/me", Some(&bot.token), None))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert!(stamp(&pool).await.is_none(), "the stamp really did fail");
}
