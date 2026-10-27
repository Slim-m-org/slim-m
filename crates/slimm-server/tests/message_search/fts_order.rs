// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The store's search answers exactly the live FTS matches in the documented
//! `(created_at, seq, id)` descending order, however the planner reaches them.

use slimm_server::ids::{ChannelId, MessageId};
use slimm_server::store::{MessageSearchFilters, NewMessage};

use crate::fixtures::*;

#[tokio::test]
async fn search_returns_the_fts_matches_in_the_documented_order() {
    let (store, pool, _guard) = new_store_with_pool().await;
    let alice = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap()
        .id;
    let alpha = store.create_channel("alpha", "text").await.unwrap().id;
    let bravo = store.create_channel("bravo", "text").await.unwrap().id;
    let plan = [
        (alpha, "otters at play", 100),
        (bravo, "otters again", 100),
        (alpha, "otter pups", 300),
        (bravo, "no match here", 250),
        (alpha, "otters sleeping", 300),
        (bravo, "otters, otters", 50),
    ];
    for (channel, content, at) in plan {
        let id = MessageId::generate();
        store
            .send_message(NewMessage::plain(channel, alice, id, content))
            .await
            .unwrap();
        set_created_at(&pool, &id.to_string(), at).await;
    }
    let scope: Vec<ChannelId> = vec![alpha, bravo];

    for fts in ["otters", "otter*", "\"otters again\"", "otters OR pups"] {
        let found = store
            .search_messages(
                &scope,
                Some(fts),
                &MessageSearchFilters::default(),
                None,
                50,
            )
            .await
            .unwrap();
        let expected: Vec<MessageId> = sqlx::query_scalar(
            "SELECT m.id FROM messages m JOIN messages_fts ON messages_fts.rowid = m.fts_rowid \
             WHERE messages_fts MATCH ? AND m.deleted_at IS NULL \
             ORDER BY m.created_at DESC, m.seq DESC, m.id DESC",
        )
        .bind(fts)
        .fetch_all(&pool)
        .await
        .unwrap();
        let ids: Vec<MessageId> = found.iter().map(|m| m.id).collect();
        assert_eq!(ids, expected, "query {fts:?}");
        assert!(!ids.is_empty(), "query {fts:?} matched nothing");
    }

    let limited = store
        .search_messages(
            &scope,
            Some("otters"),
            &MessageSearchFilters::default(),
            None,
            2,
        )
        .await
        .unwrap();
    assert_eq!(limited.len(), 2);
    assert_eq!(limited[0].created_at, 300);
}
