// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0224 against real data: a note loses a stored font_size and every other kind keeps its props.

use std::path::Path;

use slimm_server::ids::ChannelId;
use sqlx::SqlitePool;
use sqlx::migrate::Migrator;
use uuid::Uuid;

use crate::support;

const VERSION: i64 = 224;

const CHANNEL: ChannelId = ChannelId(Uuid::from_bytes([0x31; 16]));

async fn pool_at_0223() -> (SqlitePool, support::TestDbGuard) {
    let (pool, guard) = support::migration_db::empty_pool("slimm-note-font-size-migration").await;
    let mut before = Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations");
    assert!(
        before.iter().any(|m| m.version == VERSION),
        "0224 is missing"
    );
    before.migrations = before
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0223");
    (pool, guard)
}

async fn seed(pool: &SqlitePool, seq: i64, kind: &str, props: &str) -> Uuid {
    let object = Uuid::now_v7();
    sqlx::query(
        "INSERT INTO canvas_objects (id, channel_id, channel_key, kind, seq, created_at) \
         VALUES (?, ?, 1, ?, ?, 1)",
    )
    .bind(object)
    .bind(CHANNEL)
    .bind(kind)
    .bind(seq)
    .execute(pool)
    .await
    .expect("seed object");
    sqlx::query("INSERT INTO canvas_object_props (object_id, props) VALUES (?, ?)")
        .bind(object)
        .bind(props)
        .execute(pool)
        .await
        .expect("seed props");
    object
}

async fn props_of(pool: &SqlitePool, object: Uuid) -> serde_json::Value {
    let raw: String =
        sqlx::query_scalar("SELECT props FROM canvas_object_props WHERE object_id = ?")
            .bind(object)
            .fetch_one(pool)
            .await
            .unwrap();
    serde_json::from_str(&raw).unwrap()
}

#[tokio::test]
async fn a_note_loses_its_stored_font_size_and_other_kinds_keep_theirs() {
    let (pool, _guard) = pool_at_0223().await;
    sqlx::query("PRAGMA foreign_keys = OFF")
        .execute(&pool)
        .await
        .expect("seed without channels");
    let note = seed(
        &pool,
        1,
        "note",
        r#"{"text":"a","font_size":18.0,"fill":"blue"}"#,
    )
    .await;
    let plain = seed(&pool, 2, "note", r#"{"text":"b"}"#).await;
    let text = seed(&pool, 3, "text", r#"{"text":"c","font_size":18.0}"#).await;

    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
        .run(&pool)
        .await
        .expect("apply 0224");

    assert_eq!(
        props_of(&pool, note).await,
        serde_json::json!({"text": "a", "fill": "blue"})
    );
    assert_eq!(
        props_of(&pool, plain).await,
        serde_json::json!({"text": "b"})
    );
    assert_eq!(
        props_of(&pool, text).await,
        serde_json::json!({"text": "c", "font_size": 18.0})
    );
}
