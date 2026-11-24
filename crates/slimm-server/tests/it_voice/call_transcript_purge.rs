// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A deleted channel's transcripts go with it, a line seq is never handed out twice,
//! one author cannot fill a transcript's marks, and the sweep is bounded.

use slimm_server::ids::{CallTranscriptId, CallTranscriptMarkId, ChannelId, UserId};
use slimm_server::store::{
    MAX_MARKS_PER_AUTHOR, MarkKind, MarkSource, NewMark, NewTranscript, NewTranscriptLine, PutMark,
    Store, TranscriptionMode,
};

use crate::support;
use support::exports::account;

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

async fn say(store: &Store, id: CallTranscriptId, speaker: UserId, text: &str) -> i64 {
    let line = NewTranscriptLine {
        speaker,
        at: 5,
        end_at: None,
        language: None,
        text,
    };
    store
        .append_call_transcript_line(id, &line)
        .await
        .unwrap()
        .seq
}

async fn mark(store: &Store, id: CallTranscriptId, author: UserId) -> PutMark {
    let new = NewMark {
        id: CallTranscriptMarkId::generate(),
        transcript_id: id,
        author,
        at: 50,
        kind: MarkKind::Mark,
        text: None,
        source: MarkSource::Manual,
        gap_ms: 0,
    };
    store.put_call_transcript_mark(&new, 60).await.unwrap()
}

async fn user(store: &Store, name: &str) -> UserId {
    UserId(account(store, name).await.1.parse().unwrap())
}

async fn rows(store: &Store, channel: ChannelId) -> i64 {
    store
        .call_transcripts_since(channel, 0)
        .await
        .unwrap()
        .len() as i64
}

#[tokio::test]
async fn deleting_a_channel_removes_its_transcripts_even_when_retention_is_off() {
    let (store, _guard) = support::new_store("slimm-purge-channel").await;
    let alice = user(&store, "alice").await;
    let channel = store.create_channel("lounge", "voice").await.unwrap().id;
    let id = transcript(&store, channel, 10).await;
    say(&store, id, alice, "private words").await;
    mark(&store, id, alice).await;
    store
        .set_call_transcript_retention_days(None)
        .await
        .unwrap();

    assert!(store.delete_channel(channel).await.unwrap());

    assert_eq!(rows(&store, channel).await, 0);
    assert!(
        store
            .call_transcript_lines(id, 0, 10)
            .await
            .unwrap()
            .is_empty()
    );
    assert!(store.call_transcript_marks(id).await.unwrap().is_empty());
}

#[tokio::test]
async fn deleting_a_group_dm_removes_its_transcripts() {
    let (store, _guard) = support::new_store("slimm-purge-group").await;
    let alice = user(&store, "alice").await;
    let bob = user(&store, "bob").await;
    let carol = user(&store, "carol").await;
    let (group, _) = store
        .create_group_dm(alice, &[bob, carol], None, None)
        .await
        .unwrap();
    let id = transcript(&store, group.id, 10).await;
    say(&store, id, bob, "private words").await;

    assert!(store.delete_group_dm(alice, group.id).await.unwrap());

    assert_eq!(rows(&store, group.id).await, 0);
}

#[tokio::test]
async fn the_sweep_clears_transcripts_already_orphaned_by_a_deleted_channel() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-purge-orphan").await;
    let alice = user(&store, "alice").await;
    let channel = store.create_channel("lounge", "voice").await.unwrap().id;
    let id = transcript(&store, channel, 10).await;
    say(&store, id, alice, "left behind").await;
    sqlx::query("UPDATE channels SET deleted_at = 1 WHERE id = ?")
        .bind(channel)
        .execute(&pool)
        .await
        .unwrap();

    assert_eq!(store.sweep_call_transcripts(100).await.unwrap(), 1);

    assert_eq!(rows(&store, channel).await, 0);
}

#[tokio::test]
async fn a_deleted_newest_line_never_lends_its_seq() {
    let (store, _guard) = support::new_store("slimm-purge-seq").await;
    let alice = user(&store, "alice").await;
    let bob = user(&store, "bob").await;
    let channel = store.create_channel("lounge", "voice").await.unwrap().id;
    let id = transcript(&store, channel, 10).await;
    assert_eq!(say(&store, id, alice, "one").await, 1);
    assert_eq!(say(&store, id, bob, "two").await, 2);

    store.delete_account(bob).await.unwrap();

    assert_eq!(say(&store, id, alice, "three").await, 3);
}

#[tokio::test]
async fn one_author_past_their_share_is_refused_while_others_can_still_mark() {
    let (store, _guard) = support::new_store("slimm-purge-share").await;
    let alice = user(&store, "alice").await;
    let bob = user(&store, "bob").await;
    let channel = store.create_channel("lounge", "voice").await.unwrap().id;
    let id = transcript(&store, channel, 10).await;
    for _ in 0..MAX_MARKS_PER_AUTHOR {
        assert!(matches!(mark(&store, id, alice).await, PutMark::Created(_)));
    }

    assert!(matches!(mark(&store, id, alice).await, PutMark::Full));
    assert!(matches!(mark(&store, id, bob).await, PutMark::Created(_)));
}

#[tokio::test]
async fn the_sweep_stops_at_its_per_tick_cap_and_the_next_tick_finishes() {
    let (store, _guard) = support::new_store("slimm-purge-cap").await;
    let channel = store.create_channel("lounge", "voice").await.unwrap().id;
    store
        .set_call_transcript_retention_days(Some(1))
        .await
        .unwrap();
    for _ in 0..320 {
        let id = transcript(&store, channel, 10).await;
        store.end_call_transcript(id, 100).await.unwrap();
    }
    let now = 100 + 2 * 24 * 60 * 60 * 1000;

    let first = store.sweep_call_transcripts(now).await.unwrap();
    assert!(first < 320, "one tick removed {first}");
    let second = store.sweep_call_transcripts(now).await.unwrap();
    assert_eq!(first + second, 320);
}

#[tokio::test]
async fn a_long_transcript_is_deleted_in_full() {
    let (store, _guard) = support::new_store("slimm-purge-long").await;
    let alice = user(&store, "alice").await;
    let channel = store.create_channel("lounge", "voice").await.unwrap().id;
    let id = transcript(&store, channel, 10).await;
    for n in 0..1_200 {
        say(&store, id, alice, &format!("line {n}")).await;
    }

    assert!(store.delete_call_transcript(id).await.unwrap());

    assert!(
        store
            .call_transcript_lines(id, 0, 10)
            .await
            .unwrap()
            .is_empty()
    );
}
