// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0090 against real data: roles that existed before `hoist` must
//! read back hoisted, so the member pane keeps its sections, while
//! `@everyone` and roles created afterwards stay off.

use std::path::Path;
use std::time::Duration;

use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use sqlx::SqlitePool;
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};

use crate::support;
const VERSION: i64 = 90;

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

async fn pool_at_0089() -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-role-hoist-backfill");
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
    assert!(
        before.iter().any(|m| m.version == VERSION),
        "0090 is missing from ./migrations"
    );
    before.migrations = before
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0089");
    (pool, guard)
}

#[tokio::test]
async fn existing_roles_read_back_hoisted_and_everyone_does_not() {
    let (pool, _guard) = pool_at_0089().await;
    sqlx::query(
        "INSERT INTO roles (id, name, permissions, is_everyone, created_at) VALUES
         (x'01010101010101010101010101010101', '@everyone', 0, 1, 1),
         (x'02020202020202020202020202020202', 'Mod', 0, 0, 2)",
    )
    .execute(&pool)
    .await
    .expect("seed roles");

    migrator().await.run(&pool).await.expect("apply 0090");

    let store = Store::new(pool.clone());
    let roles = store.list_roles().await.expect("list roles");
    let hoist_of = |name: &str| roles.iter().find(|r| r.name == name).unwrap().hoist;
    assert!(
        hoist_of("Mod"),
        "a role from before the migration is hoisted"
    );
    assert!(!hoist_of("@everyone"), "@everyone is never a section");

    let fresh = store
        .create_role("Later", Permissions::NONE, false)
        .await
        .expect("create role");
    assert!(!store.role(fresh).await.unwrap().unwrap().hoist);
}
