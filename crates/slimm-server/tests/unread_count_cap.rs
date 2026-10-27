// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Unread counts stop at `UNREAD_COUNT_CAP` instead of counting a whole
//! never-opened history, in both the single and the batched read.

use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::store::{NewMessage, Store, UNREAD_COUNT_CAP};

mod support;

use support::app::register_id as register;

async fn fill(store: &Store, channel: ChannelId, author: UserId, count: i64) {
    for _ in 0..count {
        store
            .send_message(NewMessage::plain(
                channel,
                author,
                MessageId::generate(),
                "m",
            ))
            .await
            .unwrap();
    }
}

#[tokio::test]
async fn unread_counts_stop_at_the_cap() {
    let (store, _guard) = support::new_store("slimm-unread-cap").await;
    let author = register(&store, "author").await;
    let reader = register(&store, "reader").await;
    let big = store.list_channels().await.unwrap()[0].id;
    let small = store.create_channel("small", "text").await.unwrap().id;
    let read = store.create_channel("read", "text").await.unwrap().id;
    fill(&store, big, author, UNREAD_COUNT_CAP + 5).await;
    fill(&store, small, author, 3).await;
    fill(&store, read, author, 2).await;
    store.mark_read(reader, read, i64::MAX).await.unwrap();

    assert_eq!(
        store.unread_count(reader, big).await.unwrap(),
        UNREAD_COUNT_CAP
    );
    assert_eq!(store.unread_count(reader, small).await.unwrap(), 3);

    let counts = store
        .unread_counts(reader, &[big, small, read])
        .await
        .unwrap();
    assert_eq!(counts.get(&big), Some(&UNREAD_COUNT_CAP));
    assert_eq!(counts.get(&small), Some(&3));
    assert_eq!(counts.get(&read), None, "a fully read channel is absent");
}

#[tokio::test]
async fn thread_unread_counts_stop_at_the_cap_too() {
    let (store, _guard) = support::new_store("slimm-thread-unread-cap").await;
    let author = register(&store, "author").await;
    let reader = register(&store, "reader").await;
    let big = store.create_channel("big", "text").await.unwrap().id;
    let small = store.create_channel("small", "text").await.unwrap().id;
    let read = store.create_channel("read", "text").await.unwrap().id;
    fill(&store, big, author, UNREAD_COUNT_CAP + 5).await;
    fill(&store, small, author, 3).await;
    fill(&store, read, author, 2).await;
    store.mark_read(reader, read, i64::MAX).await.unwrap();

    let counts: std::collections::HashMap<_, _> = store
        .thread_unread_counts(&[big, small, read], reader)
        .await
        .unwrap()
        .into_iter()
        .collect();
    assert_eq!(counts.get(&big), Some(&UNREAD_COUNT_CAP));
    assert_eq!(counts.get(&small), Some(&3));
    assert_eq!(counts.get(&read), None, "a fully read thread is absent");
}
