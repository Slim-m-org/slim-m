// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The TOTP challenge sweep, the interaction sweep, and moderation history
//! paging across a shared timestamp (issue 2102).

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::UserId;
use slimm_server::store::{HistoryCursor, ModerationHistoryItem, Store};
use sqlx::SqlitePool;
use uuid::Uuid;

mod support;

async fn store(name: &str) -> (Store, SqlitePool, UserId, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let s = Store::new(pool.clone());
    let user = s.create_account("ann", "Ann", "x").await.unwrap().id;
    (s, pool, user, guard)
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

async fn rows(pool: &SqlitePool, table: &str) -> i64 {
    sqlx::query_scalar(&format!("SELECT COUNT(*) FROM {table}"))
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn the_totp_sweep_removes_only_long_expired_challenges() {
    let (s, pool, user, _guard) = store("slimm-sweep-totp").await;
    for (hash, expires_at) in [("dead", 0), ("live", now() + 60_000)] {
        sqlx::query(
            "INSERT INTO totp_challenges (challenge_hash, user_id, device_name, issued_at, expires_at)
             VALUES (?, ?, 'cli', 0, ?)",
        )
        .bind(hash)
        .bind(user)
        .bind(expires_at)
        .execute(&pool)
        .await
        .unwrap();
    }

    assert_eq!(s.sweep_expired_totp_challenges().await.unwrap(), 1);
    assert_eq!(rows(&pool, "totp_challenges").await, 1);
}

#[tokio::test]
async fn the_interaction_sweep_removes_only_stale_rows() {
    let (s, pool, user, _guard) = store("slimm-sweep-interactions").await;
    for created_at in [0, now()] {
        sqlx::query(
            "INSERT INTO interactions (id, bot_id, clicker_id, channel_id, custom_id, created_at)
             VALUES (?, ?, ?, ?, 'b', ?)",
        )
        .bind(Uuid::now_v7())
        .bind(user)
        .bind(user)
        .bind(Uuid::now_v7())
        .bind(created_at)
        .execute(&pool)
        .await
        .unwrap();
    }

    assert_eq!(s.sweep_interactions().await.unwrap(), 1);
    assert_eq!(rows(&pool, "interactions").await, 1);
}

#[tokio::test]
async fn history_pages_every_entry_once_across_a_shared_timestamp() {
    let (s, pool, user, _guard) = store("slimm-history-paging").await;
    for created_at in [100, 200, 200, 300] {
        sqlx::query(
            "INSERT INTO moderation_audit_log (subject_id, action, created_at)
             VALUES (?, 'remove', ?)",
        )
        .bind(user)
        .bind(created_at)
        .execute(&pool)
        .await
        .unwrap();
    }

    let mut seen = Vec::new();
    let mut after = None;
    loop {
        let page = s.moderation_history(after, &[], 2).await.unwrap();
        let Some(ModerationHistoryItem::Audit(last)) = page.last() else {
            break;
        };
        after = Some(HistoryCursor::Audit {
            created_at: last.created_at,
            id: last.id,
        });
        for item in &page {
            if let ModerationHistoryItem::Audit(entry) = item {
                seen.push(entry.id);
            }
        }
    }

    seen.sort_unstable();
    assert_eq!(
        seen,
        vec![1, 2, 3, 4],
        "the page break fell between the two entries at 200"
    );
}
