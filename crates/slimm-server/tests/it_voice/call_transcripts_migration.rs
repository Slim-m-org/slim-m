// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0183 against real data: an existing `@everyone` gains
//! VIEW_TRANSCRIPTS without losing what it had, other roles are left alone,
//! and the Space starts with transcription off and a 30 day window.

use std::path::Path;
use std::time::Duration;

use slimm_server::permissions::Permissions;
use slimm_server::store::{Store, TranscriptionMode};
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};

use crate::support;
const VERSION: i64 = 183;

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

#[tokio::test]
async fn an_existing_everyone_role_gains_view_transcripts_and_nothing_else_changes() {
    let (path, _guard) = support::TestDbGuard::empty("slimm-transcripts-migration");
    let options = SqliteConnectOptions::new()
        .filename(&path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .busy_timeout(Duration::from_secs(5))
        .foreign_keys(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .expect("open pool");
    let mut before = migrator().await;
    before.migrations = before
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0182");
    let held = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    sqlx::query(
        "INSERT INTO roles (id, name, permissions, is_everyone, created_at) VALUES
         (x'01010101010101010101010101010101', '@everyone', ?1, 1, 1),
         (x'02020202020202020202020202020202', 'Mod', ?1, 0, 2)",
    )
    .bind(held.bits())
    .execute(&pool)
    .await
    .expect("seed roles");

    let mut through = migrator().await;
    through.migrations = through
        .iter()
        .filter(|m| m.version <= VERSION)
        .cloned()
        .collect();
    through.run(&pool).await.expect("apply 0183");
    let bits = |name: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query_scalar::<_, i64>("SELECT permissions FROM roles WHERE name = ?1")
                .bind(name)
                .fetch_one(&pool)
                .await
                .expect("read role")
        }
    };
    assert_eq!(
        bits("@everyone").await,
        held.union(Permissions::VIEW_TRANSCRIPTS).bits()
    );
    assert_eq!(
        bits("Mod").await,
        held.bits(),
        "only @everyone is granted it"
    );

    migrator().await.run(&pool).await.expect("apply the rest");
    let store = Store::new(pool);
    assert_eq!(
        store.call_transcription().await.unwrap(),
        TranscriptionMode::Off
    );
    assert_eq!(
        store.call_transcript_retention_days().await.unwrap(),
        Some(30)
    );
}
