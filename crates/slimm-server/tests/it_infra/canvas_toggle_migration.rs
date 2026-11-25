// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0222 against real data: a voice channel keeps its canvas only when something live is on the board.
//!
//! Erased objects and media slots are not content, text channels with objects stay closed, and DMs are untouched.

use std::path::Path;

use slimm_server::ids::ChannelId;
use slimm_server::store::Store;
use sqlx::SqlitePool;
use sqlx::migrate::Migrator;
use uuid::Uuid;

use crate::support;

const VERSION: i64 = 222;

const LIVE: ChannelId = ChannelId(Uuid::from_bytes([0x21; 16]));
const ERASED_ONLY: ChannelId = ChannelId(Uuid::from_bytes([0x22; 16]));
const SLOTS_ONLY: ChannelId = ChannelId(Uuid::from_bytes([0x23; 16]));
const EMPTY: ChannelId = ChannelId(Uuid::from_bytes([0x24; 16]));
const TEXT_WITH_OBJECT: ChannelId = ChannelId(Uuid::from_bytes([0x25; 16]));
const ROOM_WITH_OBJECT: ChannelId = ChannelId(Uuid::from_bytes([0x26; 16]));
const EMPTY_ROOM: ChannelId = ChannelId(Uuid::from_bytes([0x27; 16]));
const DM: ChannelId = ChannelId(Uuid::from_bytes([0x28; 16]));

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

async fn pool_at_0221() -> (SqlitePool, support::TestDbGuard) {
    let (pool, guard) = support::migration_db::empty_pool("slimm-canvas-toggle-migration").await;
    let mut before = migrator().await;
    assert!(
        before.iter().any(|m| m.version == VERSION),
        "0222 is missing from ./migrations"
    );
    before.migrations = before
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0221");
    (pool, guard)
}

async fn seed_channel(pool: &SqlitePool, id: ChannelId, kind: &str, room: bool) {
    let lobby = room.then_some(LIVE);
    sqlx::query(
        "INSERT INTO channels (id, name, kind, position, created_at, room_lobby_id) VALUES (?, ?, ?, 0, 1, ?)",
    )
    .bind(id)
    .bind(id.to_string())
    .bind(kind)
    .bind(lobby)
    .execute(pool)
    .await
    .expect("seed channel");
}

async fn seed_object(pool: &SqlitePool, channel: ChannelId, seq: i64, erased: bool) {
    let object = Uuid::now_v7();
    sqlx::query(
        "INSERT INTO canvas_objects (id, channel_id, channel_key, kind, seq, created_at, deleted_at) \
         VALUES (?, ?, 1, 'stroke', ?, 1, ?)",
    )
    .bind(object)
    .bind(channel)
    .bind(seq)
    .bind(erased.then_some(2_i64))
    .execute(pool)
    .await
    .expect("seed object");
}

#[tokio::test]
async fn only_a_voice_channel_with_a_live_object_keeps_its_canvas() {
    let (pool, _guard) = pool_at_0221().await;
    sqlx::query("PRAGMA foreign_keys = OFF")
        .execute(&pool)
        .await
        .expect("seed without users");
    seed_channel(&pool, LIVE, "voice", false).await;
    seed_channel(&pool, ERASED_ONLY, "voice", false).await;
    seed_channel(&pool, SLOTS_ONLY, "voice", false).await;
    seed_channel(&pool, EMPTY, "voice", false).await;
    seed_channel(&pool, TEXT_WITH_OBJECT, "text", false).await;
    seed_channel(&pool, ROOM_WITH_OBJECT, "voice", true).await;
    seed_channel(&pool, EMPTY_ROOM, "voice", true).await;
    seed_channel(&pool, DM, "dm", false).await;
    seed_object(&pool, LIVE, 1, false).await;
    seed_object(&pool, ERASED_ONLY, 1, true).await;
    seed_object(&pool, TEXT_WITH_OBJECT, 1, false).await;
    seed_object(&pool, ROOM_WITH_OBJECT, 1, false).await;
    sqlx::query(
        "INSERT INTO canvas_media_slots (channel_id, user_id, kind, x, y, w, h, updated_at) \
         VALUES (?, x'99999999999999999999999999999999', 'camera', 0, 0, 10, 10, 1)",
    )
    .bind(SLOTS_ONLY)
    .execute(&pool)
    .await
    .expect("seed slot");

    migrator().await.run(&pool).await.expect("apply 0222");

    let store = Store::new(pool.clone());
    let open = |id: ChannelId| {
        let store = store.clone();
        async move { store.channel(id).await.unwrap().unwrap().canvas_open() }
    };
    assert!(open(LIVE).await, "a live object keeps the canvas on");
    assert!(!open(ERASED_ONLY).await, "an erased object is not content");
    assert!(!open(SLOTS_ONLY).await, "a media slot is not content");
    assert!(!open(EMPTY).await, "an empty board goes off");
    assert!(!open(TEXT_WITH_OBJECT).await, "text channels stay closed");
    assert!(open(ROOM_WITH_OBJECT).await, "a room follows the same rule");
    assert!(!open(EMPTY_ROOM).await, "an empty room goes off");
    assert!(open(DM).await, "a DM is always open");
    let stored: i64 = sqlx::query_scalar("SELECT canvas_enabled FROM channels WHERE id = ?")
        .bind(DM)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(stored, 0, "the migration never touches a DM row");
}
