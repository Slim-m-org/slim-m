// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0186 against real data: an existing `@everyone` role gains
//! USE_SOUNDBOARD without losing what it had, and other roles are left alone.

use std::path::Path;
use std::time::Duration;

use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};

use crate::support;
const VERSION: i64 = 186;

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

#[tokio::test]
async fn an_existing_everyone_role_gains_use_soundboard_and_other_roles_do_not() {
    let (path, _guard) = support::TestDbGuard::empty("slimm-soundboard-migration");
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
    before.run(&pool).await.expect("migrate to 0185");
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

    migrator().await.run(&pool).await.expect("apply 0186");

    let roles = Store::new(pool).list_roles().await.expect("list roles");
    let bits = |name: &str| {
        roles
            .iter()
            .find(|r| r.name == name)
            .unwrap()
            .permissions
            .bits()
    };
    assert_eq!(
        bits("@everyone"),
        held.union(Permissions::USE_SOUNDBOARD).bits()
    );
    assert_eq!(bits("Mod"), held.bits());
}
