// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for the message store against a real embedded SQLite db.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{MessageId, Seq};
use slimm_server::store::{Edited, NewMessage, Store};

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

#[tokio::test]
async fn seq_is_monotonic_and_independent_per_channel() {
    let (s, _guard) = store().await;
    let author = s.create_user("mara", "Mara").await.unwrap();
    let a = s.create_channel("general", "text").await.unwrap();
    let b = s.create_channel("gaming", "text").await.unwrap();

    let a1 = s
        .send_message(NewMessage::plain(
            a.id,
            author.id,
            MessageId::generate(),
            "one",
        ))
        .await
        .unwrap()
        .message;
    let a2 = s
        .send_message(NewMessage::plain(
            a.id,
            author.id,
            MessageId::generate(),
            "two",
        ))
        .await
        .unwrap()
        .message;
    let b1 = s
        .send_message(NewMessage::plain(
            b.id,
            author.id,
            MessageId::generate(),
            "other",
        ))
        .await
        .unwrap()
        .message;

    assert_eq!(a1.seq, Seq(1));
    assert_eq!(a2.seq, Seq(2));
    // A separate channel has its own counter, so this is 1, not 3.
    assert_eq!(b1.seq, Seq(1));
}

#[tokio::test]
async fn send_is_idempotent_by_id() {
    let (s, _guard) = store().await;
    let author = s.create_user("theo", "Theo").await.unwrap();
    let c = s.create_channel("general", "text").await.unwrap();

    let id = MessageId::generate();
    let first = s
        .send_message(NewMessage::plain(c.id, author.id, id, "hi"))
        .await
        .unwrap()
        .message;
    // A retry with the same id returns the stored message and wastes no sequence.
    let retry = s
        .send_message(NewMessage::plain(c.id, author.id, id, "hi again"))
        .await
        .unwrap()
        .message;

    assert_eq!(first.seq, retry.seq);
    assert_eq!(first.id, retry.id);
    assert_eq!(
        retry.content, "hi",
        "returns the stored message, not the retry body"
    );

    // The next real send is seq 2, proving the retry did not consume seq 2.
    let second = s
        .send_message(NewMessage::plain(
            c.id,
            author.id,
            MessageId::generate(),
            "second",
        ))
        .await
        .unwrap()
        .message;
    assert_eq!(second.seq, Seq(2));

    let all = s.list_messages(c.id, None, 100).await.unwrap();
    assert_eq!(all.len(), 2, "the retry did not create a duplicate row");
}

#[tokio::test]
async fn edit_and_keyset_pagination() {
    let (s, _guard) = store().await;
    let author = s.create_user("priya", "Priya").await.unwrap();
    let c = s.create_channel("general", "text").await.unwrap();
    for i in 0..5 {
        s.send_message(NewMessage::plain(
            c.id,
            author.id,
            MessageId::generate(),
            &format!("m{i}"),
        ))
        .await
        .unwrap();
    }

    // Newest-first page of 3.
    let page = s.list_messages(c.id, None, 3).await.unwrap();
    assert_eq!(page.len(), 3);
    assert_eq!(page[0].seq, Seq(5));
    assert_eq!(page[2].seq, Seq(3));

    // Page backwards from the smallest seq seen.
    let next = s.list_messages(c.id, Some(page[2].seq.0), 3).await.unwrap();
    assert_eq!(next.len(), 2);
    assert_eq!(next[0].seq, Seq(2));
    assert_eq!(next[1].seq, Seq(1));

    // Edit stamps edited_at and changes the content.
    let Edited::Edited {
        message: edited, ..
    } = s
        .edit_message(page[0].id, "edited", author.id)
        .await
        .unwrap()
    else {
        panic!("a real content change must report itself as an edit");
    };
    assert_eq!(edited.content, "edited");
    assert!(edited.edited_at.is_some());

    // Editing something that does not exist is a clean Gone.
    assert!(matches!(
        s.edit_message(MessageId::generate(), "x", author.id)
            .await
            .unwrap(),
        Edited::Gone
    ));
}

#[tokio::test]
async fn a_retry_reports_itself_as_a_retry() {
    let (s, _guard) = store().await;
    let author = s.create_user("rae", "Rae").await.unwrap();
    let c = s.create_channel("general", "text").await.unwrap();
    let id = MessageId::generate();

    let first = s
        .send_message(NewMessage::plain(c.id, author.id, id, "hi"))
        .await
        .unwrap();
    assert!(first.fresh, "a first send is fresh");

    let retry = s
        .send_message(NewMessage::plain(c.id, author.id, id, "hi"))
        .await
        .unwrap();
    assert!(
        !retry.fresh,
        "a replayed id must be flagged, or the caller fans it out and pushes it a second time"
    );
    assert_eq!(retry.message.seq, first.message.seq);
}

/// The per-channel counter is allocated inside the send transaction, and that
/// transaction reads the message id before it writes. Every other test here
/// drives it one call at a time, which cannot catch either a duplicate seq or
/// the SQLITE_BUSY a deferred transaction hits when it tries to promote a read
/// snapshot to a write.
#[tokio::test]
async fn concurrent_sends_each_take_a_distinct_sequence_number() {
    const SENDERS: usize = 24;

    let (s, _guard) = store().await;
    let author = s.create_user("nils", "Nils").await.unwrap();
    let c = s.create_channel("general", "text").await.unwrap();

    let sends = (0..SENDERS).map(|i| {
        let s = s.clone();
        let channel = c.id;
        let author = author.id;
        tokio::spawn(async move {
            s.send_message(NewMessage::plain(
                channel,
                author,
                MessageId::generate(),
                &format!("m{i}"),
            ))
            .await
        })
    });
    let results = futures_util::future::join_all(sends).await;

    let mut seqs: Vec<i64> = Vec::with_capacity(SENDERS);
    for result in results {
        let sent = result
            .expect("send task panicked")
            .expect("a concurrent send must not fail");
        assert!(sent.fresh);
        seqs.push(sent.message.seq.0);
    }
    seqs.sort_unstable();
    let expected: Vec<i64> = (1..=SENDERS as i64).collect();
    assert_eq!(
        seqs, expected,
        "every concurrent send must take its own sequence number, with no gap and no duplicate"
    );
}
