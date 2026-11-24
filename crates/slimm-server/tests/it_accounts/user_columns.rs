// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every column of the migrated schema that holds a member's id, for the
//! lifecycle coverage tests: the ones with a foreign key to `users`, and the
//! ones named for a person that have none, since a missing key must not be a
//! way for member data to skip its deletion and export decisions.
//!
//! Polymorphic columns (`target_id`, `subject_id`) name a member or something
//! else by a sibling kind column; the tables that use them are covered through
//! their user-keyed columns or by name in each test's own decisions.

use slimm_server::config::Config;
use slimm_server::db;
use sqlx::{AssertSqlSafe, Row};

use crate::support;

/// The roles a column can name a person in, as `<role>_id` or `..._<role>_id`.
const PERSON_ROLES: &[&str] = &[
    "user", "author", "actor", "owner", "speaker", "sender", "clicker", "caller", "uploader", "bot",
];

/// Whether a column's name says it holds a person's id.
pub fn names_a_person(column: &str) -> bool {
    column.ends_with("_by")
        || PERSON_ROLES
            .iter()
            .any(|role| column == format!("{role}_id") || column.ends_with(&format!("_{role}_id")))
}

/// Every `(table, column)` holding a user id, sorted.
pub async fn user_columns(prefix: &str) -> Vec<(String, String)> {
    let (path, _guard) = support::TestDbGuard::new(prefix);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");

    let tables: Vec<String> = sqlx::query(
        "SELECT name FROM sqlite_master WHERE type = 'table' \
         AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_sqlx%' ORDER BY name",
    )
    .fetch_all(&pool)
    .await
    .expect("list tables")
    .into_iter()
    .map(|row| row.get::<String, _>("name"))
    .collect();

    let mut found = Vec::new();
    for table in tables {
        let fks = sqlx::query(AssertSqlSafe(format!("PRAGMA foreign_key_list({table})")))
            .fetch_all(&pool)
            .await
            .expect("foreign keys");
        let keyed: Vec<String> = fks
            .iter()
            .filter(|fk| fk.get::<String, _>("table") == "users")
            .map(|fk| fk.get::<String, _>("from"))
            .collect();
        let columns = sqlx::query(AssertSqlSafe(format!("PRAGMA table_info({table})")))
            .fetch_all(&pool)
            .await
            .expect("columns");
        for column in columns {
            let name: String = column.get("name");
            if keyed.contains(&name) || names_a_person(&name) {
                found.push((table.clone(), name));
            }
        }
    }
    // users.id is what every other reference points at, and has no foreign key of its own to be found.
    found.push(("users".to_owned(), "id".to_owned()));
    found.sort();
    found.dedup();
    found
}

#[test]
fn a_person_named_column_is_recognised_and_a_plain_id_is_not() {
    for named in [
        "user_id",
        "clear_author_id",
        "issued_by",
        "bot_id",
        "origin_author_id",
    ] {
        assert!(names_a_person(named), "{named}");
    }
    for plain in ["id", "channel_id", "message_id", "target_id", "busybody"] {
        assert!(!names_a_person(plain), "{plain}");
    }
}
