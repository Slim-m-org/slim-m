// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A transcript's marks go with it: deleting it, its retention sweep and the
//! author's account deletion remove them, and a member's export holds their own.

use slimm_server::ids::{CallTranscriptId, CallTranscriptMarkId, ChannelId, UserId};
use slimm_server::store::{
    MarkKind, MarkSource, NewMark, NewTranscript, PutMark, Store, TranscriptionMode,
};

use crate::support;
use support::app::general_channel_id;
use support::exports::{account, world};

async fn transcript(store: &Store, channel: ChannelId, started_at: i64) -> CallTranscriptId {
    let id = CallTranscriptId::generate();
    let new = NewTranscript {
        id,
        channel_id: channel,
        started_at,
        mode: TranscriptionMode::Always,
        started_by: None,
    };
    store.begin_call_transcript(&new).await.unwrap();
    id
}

async fn mark(store: &Store, id: CallTranscriptId, author: UserId, text: Option<&str>) {
    let new = NewMark {
        id: CallTranscriptMarkId::generate(),
        transcript_id: id,
        author,
        at: 50,
        kind: if text.is_some() {
            MarkKind::Note
        } else {
            MarkKind::Mark
        },
        text,
        source: MarkSource::Manual,
        gap_ms: 0,
    };
    let put = store.put_call_transcript_mark(&new, 60).await.unwrap();
    assert!(matches!(put, PutMark::Created(_)), "{put:?}");
}

async fn people(store: &Store) -> (String, UserId, UserId, ChannelId) {
    let (alice, alice_id) = account(store, "alice").await;
    let (_, bob_id) = account(store, "bob").await;
    let channel = ChannelId(general_channel_id(store).await.parse().unwrap());
    (
        alice,
        UserId(alice_id.parse().unwrap()),
        UserId(bob_id.parse().unwrap()),
        channel,
    )
}

#[tokio::test]
async fn deleting_a_transcript_or_sweeping_it_removes_its_marks() {
    let (store, _guard) = support::new_store("slimm-marks-delete").await;
    let (_, alice, bob, channel) = people(&store).await;
    let deleted = transcript(&store, channel, 10).await;
    let swept = transcript(&store, channel, 10).await;
    let kept = transcript(&store, channel, 10).await;
    for id in [deleted, swept, kept] {
        mark(&store, id, alice, None).await;
        mark(&store, id, bob, Some("bob's note")).await;
    }
    for id in [deleted, swept] {
        store.end_call_transcript(id, 100).await.unwrap();
    }

    assert!(store.delete_call_transcript(deleted).await.unwrap());
    store
        .set_call_transcript_retention_days(Some(1))
        .await
        .unwrap();
    let day = 24 * 60 * 60 * 1000;
    assert_eq!(
        store.sweep_call_transcripts(100 + 2 * day).await.unwrap(),
        1
    );

    for id in [deleted, swept] {
        assert!(store.call_transcript_marks(id).await.unwrap().is_empty());
    }
    assert_eq!(store.call_transcript_marks(kept).await.unwrap().len(), 2);
}

#[tokio::test]
async fn an_account_deletion_removes_that_persons_marks_only() {
    let (store, _guard) = support::new_store("slimm-marks-account").await;
    let (_, alice, bob, channel) = people(&store).await;
    let id = transcript(&store, channel, 10).await;
    mark(&store, id, alice, Some("alice's note")).await;
    mark(&store, id, bob, None).await;

    store.delete_account(bob).await.unwrap();

    let left = store.call_transcript_marks(id).await.unwrap();
    assert_eq!(left.len(), 1);
    assert_eq!(
        left[0].author_id, alice,
        "the first account owns the Space and stays"
    );
}

#[tokio::test]
async fn a_member_export_holds_only_their_own_marks() {
    let (store, _guard) = support::new_store("slimm-marks-export").await;
    let w = world(store.clone());
    let (alice_token, alice, bob, channel) = people(&store).await;
    let id = transcript(&store, channel, 10).await;
    mark(&store, id, alice, Some("alice wrote this")).await;
    mark(&store, id, bob, Some("bob wrote this")).await;

    let archive = w.archive(&alice_token, "member").await;
    let marks = archive.lines("transcript_marks.jsonl");
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0]["text"], "alice wrote this");
    assert_eq!(marks[0]["kind"], "note");
    assert!(!archive.contains("bob wrote this"));
}
