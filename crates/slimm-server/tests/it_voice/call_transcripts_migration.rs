// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0183 against real data: an existing `@everyone` gains
//! VIEW_TRANSCRIPTS without losing what it had, other roles are left alone,
//! and the Space starts with transcription off and a 30 day window. Then 0195:
//! a line kept before it reads back with no end time and no language.

use std::path::Path;

use slimm_server::ids::CallTranscriptId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{Store, TranscriptionMode};
use sqlx::migrate::Migrator;

use crate::support;
const VERSION: i64 = 183;
const LINE_TIMES: i64 = 195;

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

#[tokio::test]
async fn an_existing_everyone_role_gains_view_transcripts_and_nothing_else_changes() {
    let (pool, _guard) = support::migration_db::empty_pool("slimm-transcripts-migration").await;
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

#[tokio::test]
async fn a_line_kept_before_0195_has_no_end_time_or_language() {
    let (path, _guard) = support::TestDbGuard::empty("slimm-transcript-lines-migration");
    let pool =
        support::migration_db::pool(support::migration_db::options(&path).foreign_keys(false))
            .await;
    let mut before = migrator().await;
    before.migrations = before
        .iter()
        .filter(|m| m.version < LINE_TIMES)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0194");
    let transcript = CallTranscriptId::generate();
    sqlx::query(
        "INSERT INTO call_transcript_lines (transcript_id, seq, speaker_id, at, text)
         VALUES (?1, 1, x'03030303030303030303030303030303', 10, 'said before')",
    )
    .bind(transcript)
    .execute(&pool)
    .await
    .expect("seed a line");

    migrator().await.run(&pool).await.expect("apply 0195");
    let lines = Store::new(pool)
        .call_transcript_lines(transcript, 0, 10)
        .await
        .unwrap();
    assert_eq!(lines.len(), 1);
    assert_eq!((lines[0].at, lines[0].text.as_str()), (10, "said before"));
    assert_eq!(
        (lines[0].end_at, lines[0].language.as_deref()),
        (None, None)
    );
}
