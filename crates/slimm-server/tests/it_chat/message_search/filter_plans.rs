// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The rare-kind filters start from the few messages that carry the kind, not
//! from every message in scope: over an analyzed channel of thousands, a
//! `has:poll` or `pinned:true` search looks messages up by id instead of
//! walking the channel and probing each row.

use slimm_server::store::{HasKind, MessageSearchFilters};
use sqlx::{QueryBuilder, Row, Sqlite};

use crate::message_search::fixtures::*;

async fn plan(
    conn: &mut sqlx::SqliteConnection,
    filters: &MessageSearchFilters,
    channel: &[u8],
) -> String {
    let mut builder: QueryBuilder<Sqlite> =
        QueryBuilder::new("EXPLAIN QUERY PLAN SELECT m.id FROM messages m WHERE m.channel_id IN (");
    builder.push_bind(channel.to_vec());
    builder.push(") AND m.deleted_at IS NULL AND m.seq < ");
    builder.push_bind(i64::MAX);
    filters.push_predicates(&mut builder);
    builder.push(" ORDER BY m.created_at DESC, m.seq DESC, m.id DESC LIMIT 25");
    let rows = builder.build().fetch_all(conn).await.unwrap();
    rows.iter()
        .map(|row| row.get::<String, _>("detail"))
        .collect::<Vec<_>>()
        .join("\n")
}

#[tokio::test]
async fn rare_kinds_look_messages_up_by_id() {
    let (store, pool, _guard) = new_store_with_pool().await;
    let channel = store.create_channel("busy", "text").await.unwrap();
    let id: Vec<u8> = channel.id.0.as_bytes().to_vec();
    sqlx::query(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000) \
         INSERT INTO messages (id, channel_id, seq, content, is_encrypted, created_at) \
         SELECT randomblob(16), ?, i, 'hello ' || i, 0, i FROM n",
    )
    .bind(&id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO polls (message_id, channel_id, question, created_at) \
         SELECT id, channel_id, 'q', 0 FROM messages WHERE seq % 5000 = 0",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO pinned_messages (channel_id, message_id, pinned_at) \
         SELECT channel_id, id, 0 FROM messages WHERE seq % 4000 = 0",
    )
    .execute(&pool)
    .await
    .unwrap();
    // Stats load per connection, so the plan is read on the one that analyzed.
    let mut conn = pool.acquire().await.unwrap();
    sqlx::query("ANALYZE").execute(&mut *conn).await.unwrap();

    let polls = MessageSearchFilters {
        has: vec![HasKind::Poll],
        ..Default::default()
    };
    let pinned = MessageSearchFilters {
        pinned: Some(true),
        ..Default::default()
    };
    for (name, filters) in [("has:poll", polls), ("pinned:true", pinned)] {
        let plan = plan(&mut conn, &filters, &id).await;
        assert!(
            plan.contains("SEARCH m USING INDEX sqlite_autoindex_messages_1 (id=?)"),
            "{name} must look messages up by id, not walk the channel:\n{plan}"
        );
    }
}
