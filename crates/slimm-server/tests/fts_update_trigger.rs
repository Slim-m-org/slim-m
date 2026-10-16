// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The FTS update trigger runs only when indexed text changes: a metadata
//! update leaves the index alone, an edit still re-indexes (issue 2060).

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::MessageId;
use slimm_server::store::{NewMessage, Store};
use sqlx::SqlitePool;

mod support;

/// Rows in the FTS segment table: every index write appends one until a merge.
async fn index_segments(pool: &SqlitePool) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM messages_fts_data")
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn only_a_content_change_touches_the_search_index() {
    let (path, _guard) = support::TestDbGuard::new("slimm-fts-trigger");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.unwrap();
    let s = Store::new(pool.clone());
    let user = s.create_account("ann", "Ann", "x").await.unwrap().id;
    s.bootstrap_deployment(user).await.unwrap();
    let channel = s.create_channel("general-fts", "text").await.unwrap();
    let id = MessageId::generate();
    s.send_message(NewMessage::plain(channel.id, user, id, "pelicans gather"))
        .await
        .unwrap();

    let before = index_segments(&pool).await;
    for at in 1..=5 {
        sqlx::query("UPDATE messages SET edited_at = ?, author_id = NULL WHERE id = ?")
            .bind(at)
            .bind(id)
            .execute(&pool)
            .await
            .unwrap();
    }
    assert_eq!(
        index_segments(&pool).await,
        before,
        "a metadata update re-indexed the row"
    );

    sqlx::query("UPDATE messages SET content = 'flamingos gather' WHERE id = ?")
        .bind(id)
        .execute(&pool)
        .await
        .unwrap();
    let found: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'flamingos'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(found, 1, "an edit no longer reached the index");
}
