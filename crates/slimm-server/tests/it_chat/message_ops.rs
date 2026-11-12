// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The message op stream, against a real embedded SQLite database.
//!
//! What these bind is density: after N real edits and deletes, the feed holds
//! exactly N rows with consecutive seqs and no holes. Every other test here
//! exists because some way of writing the code would put a hole in it - a seq
//! allocated for a mutation that did not happen, or a row written twice for
//! one state transition.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::store::{Edited, MessageOpKind, MessageSearchFilters, NewMessage, Store};

use crate::support;
async fn store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

async fn send(s: &Store, channel: ChannelId, author: UserId, body: &str) -> MessageId {
    s.send_message(NewMessage::plain(
        channel,
        author,
        MessageId::generate(),
        body,
    ))
    .await
    .unwrap()
    .message
    .id
}

/// The property everything else here protects.
///
/// A hole would break the client's `seq == cursor + 1` adjacency test, which
/// is what lets it tell "I am up to date" from "I missed something", so a
/// single stray allocation turns a working cursor into one that reports a gap
/// on every poll forever.
#[tokio::test]
async fn the_op_sequence_is_dense_over_mixed_edits_and_deletes() {
    let (s, _guard) = store().await;
    let author = s.create_user("mara", "Mara").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap().id;

    let a = send(&s, channel, author.id, "one").await;
    let b = send(&s, channel, author.id, "two").await;
    let c = send(&s, channel, author.id, "three").await;

    s.edit_message(a, "one, revised", author.id).await.unwrap();
    s.delete_message(b, author.id).await.unwrap();
    s.edit_message(c, "three, revised", author.id)
        .await
        .unwrap();
    s.edit_message(a, "one, revised again", author.id)
        .await
        .unwrap();

    let page = s.message_ops_since(channel, 0, 100).await.unwrap();
    let seqs: Vec<i64> = page.ops.iter().map(|op| op.seq).collect();
    assert_eq!(seqs, vec![1, 2, 3, 4], "the sequence must have no holes");
    assert_eq!(page.latest_seq, 4);
    let kinds: Vec<MessageOpKind> = page.ops.iter().map(|op| op.kind).collect();
    assert_eq!(
        kinds,
        vec![
            MessageOpKind::Edit,
            MessageOpKind::Delete,
            MessageOpKind::Edit,
            MessageOpKind::Edit
        ]
    );
}

/// An edit to byte-identical content is not an edit.
///
/// Today's code stamps `edited_at` and republishes for it, so this is a
/// visible behaviour change and not only an internal one. It has to be: a seq
/// allocated for a mutation nobody made is a hole the client cannot close,
/// since no op row would ever carry it.
#[tokio::test]
async fn an_edit_to_identical_content_writes_no_op_and_leaves_edited_at_alone() {
    let (s, _guard) = store().await;
    let author = s.create_user("mara", "Mara").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap().id;
    let id = send(&s, channel, author.id, "unchanged").await;

    let outcome = s.edit_message(id, "unchanged", author.id).await.unwrap();
    let Edited::Unchanged(message) = outcome else {
        panic!("byte-identical content must report itself as unchanged");
    };
    assert!(
        message.edited_at.is_none(),
        "a message nobody changed must not be marked as edited"
    );

    let page = s.message_ops_since(channel, 0, 100).await.unwrap();
    assert!(page.ops.is_empty(), "no op row for a mutation that was not");
    assert_eq!(page.latest_seq, 0, "and no seq allocated for it either");
}

/// The `UPDATE ... WHERE deleted_at IS NULL` is the claim and the idempotency
/// check in one, so a retry after a dropped response must write nothing.
#[tokio::test]
async fn a_repeated_delete_writes_exactly_one_op() {
    let (s, _guard) = store().await;
    let author = s.create_user("mara", "Mara").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap().id;
    let id = send(&s, channel, author.id, "goodbye").await;

    let first = s.delete_message(id, author.id).await.unwrap();
    assert!(first.deleted);
    assert_eq!(first.op_seq, Some(1));

    let retry = s.delete_message(id, author.id).await.unwrap();
    assert!(!retry.deleted, "the second call deleted nothing");
    assert_eq!(retry.op_seq, None, "so it must not have allocated a seq");

    let page = s.message_ops_since(channel, 0, 100).await.unwrap();
    assert_eq!(page.ops.len(), 1);
    assert_eq!(page.latest_seq, 1);
}

/// Content is joined at read time rather than stored on the op, so a message
/// deleted after being edited carries no text on its own earlier edit op.
///
/// Without this an op stream would hand a reader the words of a message the
/// server no longer serves anywhere else.
#[tokio::test]
async fn an_edit_op_loses_its_content_once_the_message_is_deleted() {
    let (s, _guard) = store().await;
    let author = s.create_user("mara", "Mara").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap().id;
    let id = send(&s, channel, author.id, "before").await;

    s.edit_message(id, "after", author.id).await.unwrap();
    let page = s.message_ops_since(channel, 0, 100).await.unwrap();
    assert_eq!(page.ops[0].content.as_deref(), Some("after"));

    s.delete_message(id, author.id).await.unwrap();
    let page = s.message_ops_since(channel, 0, 100).await.unwrap();
    assert_eq!(page.ops.len(), 2);
    assert_eq!(
        page.ops[0].content, None,
        "the edit op must not still carry the deleted message's words"
    );
    assert_eq!(page.ops[0].kind, MessageOpKind::Edit);
    assert_eq!(page.ops[1].kind, MessageOpKind::Delete);
}

/// No channel-creation path writes a `'message_op'` counter row, so every
/// channel that exists today is in exactly the state a pre-0027 one is: the
/// first op has to allocate the row itself.
///
/// This is what makes migration 0027 safe to ship with no backfill, so it is
/// the test that fails if the upsert is ever "simplified" into the
/// `UPDATE ... RETURNING` shape the message counter uses.
#[tokio::test]
async fn the_first_op_in_a_channel_allocates_its_own_counter_row() {
    let (s, _guard) = store().await;
    let author = s.create_user("mara", "Mara").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap().id;
    let id = send(&s, channel, author.id, "hello").await;

    assert_eq!(
        s.message_ops_since(channel, 0, 100)
            .await
            .unwrap()
            .latest_seq,
        0,
        "nothing has allocated the counter yet"
    );

    s.edit_message(id, "hello again", author.id).await.unwrap();
    let page = s.message_ops_since(channel, 0, 100).await.unwrap();
    assert_eq!(page.ops[0].seq, 1, "the first op takes seq 1, never 0 or 2");
    assert_eq!(page.latest_seq, 1);
}

/// `edit_message` reads before it writes, and a deferred transaction that has
/// taken a read snapshot cannot promote itself to a writer: SQLite answers
/// SQLITE_BUSY immediately and ignores `busy_timeout`.
///
/// The phase-3 audit found exactly this shape in three other transactions,
/// where it surfaced as "database is locked" rather than as a wrong answer.
#[tokio::test]
async fn concurrent_edits_to_one_channel_all_succeed() {
    let (s, _guard) = store().await;
    let author = s.create_user("mara", "Mara").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap().id;

    let mut ids = Vec::new();
    for i in 0..24 {
        ids.push(send(&s, channel, author.id, &format!("body {i}")).await);
    }

    let mut handles = Vec::new();
    for (i, id) in ids.into_iter().enumerate() {
        let store = s.clone();
        handles.push(tokio::spawn(async move {
            store
                .edit_message(id, &format!("revised {i}"), author.id)
                .await
        }));
    }
    for handle in handles {
        let outcome = handle.await.unwrap().expect("no edit may be locked out");
        assert!(matches!(outcome, Edited::Edited { .. }));
    }

    let page = s.message_ops_since(channel, 0, 100).await.unwrap();
    let seqs: Vec<i64> = page.ops.iter().map(|op| op.seq).collect();
    assert_eq!(
        seqs,
        (1..=24).collect::<Vec<i64>>(),
        "24 concurrent allocations must still be dense"
    );
}

/// The op row is the only record anywhere of who deleted a message, so it has
/// to be anonymised with everything else the account authored.
///
/// `canvas_ops` went without this until somebody wrote it down, which is why
/// it gets a test here rather than a reviewer's attention.
#[tokio::test]
async fn account_deletion_nulls_the_actor_of_an_op() {
    let (s, _guard) = store().await;
    let author = s.create_user("mara", "Mara").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap().id;
    let id = send(&s, channel, author.id, "hello").await;
    s.edit_message(id, "hello again", author.id).await.unwrap();

    s.delete_account(author.id).await.unwrap();

    let page = s.message_ops_since(channel, 0, 100).await.unwrap();
    assert_eq!(page.ops.len(), 1, "the op row itself survives");
    assert_eq!(
        page.ops[0].actor_id, None,
        "a deleted account must not stay named as the actor"
    );
}

/// Moving the edit into a transaction must not have broken the FTS trigger,
/// which is what keeps a message findable under its new words.
#[tokio::test]
async fn an_edited_message_is_findable_under_its_new_content() {
    let (s, _guard) = store().await;
    let author = s.create_user("mara", "Mara").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap().id;
    let id = send(&s, channel, author.id, "aardvark").await;

    s.edit_message(id, "pangolin", author.id).await.unwrap();

    let hits = s
        .search_messages(
            &[channel],
            Some("pangolin"),
            &MessageSearchFilters::default(),
            None,
            10,
        )
        .await
        .unwrap();
    assert_eq!(hits.len(), 1, "the new content must be indexed");
    assert_eq!(hits[0].id, id);
    let stale = s
        .search_messages(
            &[channel],
            Some("aardvark"),
            &MessageSearchFilters::default(),
            None,
            10,
        )
        .await
        .unwrap();
    assert!(stale.is_empty(), "and the old content must not be");
}
