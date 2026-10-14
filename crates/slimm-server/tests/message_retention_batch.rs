// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The batched retention prune's own invariants: op seqs stay dense per
//! channel across a multi-channel batch, and a content-addressed attachment is
//! freed exactly once and only when nothing outside the batch still holds it.
//! Its own file because `message_retention.rs` is already at the line budget.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{CanvasObjectId, ChannelId, MessageId, UserId};
use slimm_server::store::{NewMessage, PlaceRequest, Store};
use sqlx::SqlitePool;

mod support;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

async fn harness(name: &str) -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

async fn register(store: &Store, username: &str) -> UserId {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    account.id
}

async fn general(store: &Store) -> ChannelId {
    store.list_channels().await.unwrap()[0].id
}

async fn backdate_message(pool: &SqlitePool, id: MessageId, created_at: i64) {
    sqlx::query("UPDATE messages SET created_at = ? WHERE id = ?")
        .bind(created_at)
        .bind(id)
        .execute(pool)
        .await
        .unwrap();
}

async fn send_old(s: &Store, pool: &SqlitePool, channel: ChannelId, author: UserId, sha: &[u8]) {
    let attachments: Vec<Vec<u8>> = if sha.is_empty() {
        Vec::new()
    } else {
        vec![sha.to_vec()]
    };
    let id = s
        .send_message(NewMessage {
            channel_id: channel,
            author_id: author,
            id: MessageId::generate(),
            content: "old",
            attachment_ids: &attachments,
            spoiler_ids: &[],
            reply_to_id: None,
            forward: None,
        })
        .await
        .unwrap()
        .message
        .id;
    backdate_message(pool, id, -60 * DAY_MS).await;
}

#[tokio::test]
async fn a_batch_across_two_channels_gives_each_its_own_dense_op_seqs() {
    let (s, pool, _guard) = harness("slimm-retention-multichannel").await;
    let admin = register(&s, "root").await;
    let general = general(&s).await;
    let other = s.create_channel("other", "text").await.unwrap().id;
    s.set_message_retention_days(30).await.unwrap();

    // Two old messages in general, three in other, all past the window.
    for _ in 0..2 {
        send_old(&s, &pool, general, admin, &[]).await;
    }
    for _ in 0..3 {
        send_old(&s, &pool, other, admin, &[]).await;
    }

    let swept = s.sweep_message_retention().await.unwrap();
    assert_eq!(swept.pruned.len(), 5);

    // Each channel's delete ops are dense from 1, with no seq leak between them.
    let general_ops = s.message_ops_since(general, 0, 100).await.unwrap();
    assert_eq!(
        general_ops.ops.iter().map(|o| o.seq).collect::<Vec<_>>(),
        vec![1, 2]
    );
    let other_ops = s.message_ops_since(other, 0, 100).await.unwrap();
    assert_eq!(
        other_ops.ops.iter().map(|o| o.seq).collect::<Vec<_>>(),
        vec![1, 2, 3]
    );

    // Every pruned message reports the exact op_seq its own channel carries.
    for pruned in &swept.pruned {
        let ops = if pruned.channel_id == general {
            &general_ops
        } else {
            &other_ops
        };
        let entry = ops
            .ops
            .iter()
            .find(|o| o.message_id == pruned.message_id)
            .expect("pruned message must have a delete op in its channel");
        assert_eq!(pruned.op_seq, Some(entry.seq));
    }
}

#[tokio::test]
async fn a_shared_attachment_across_two_pruned_messages_is_freed_once() {
    let (s, pool, _guard) = harness("slimm-retention-shared-attach").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    s.set_message_retention_days(30).await.unwrap();

    let sha256 = vec![9u8; 32];
    s.store_attachment(&sha256, 1_000, "image/png", "shared.png", Some(admin))
        .await
        .unwrap();
    send_old(&s, &pool, channel, admin, &sha256).await;
    send_old(&s, &pool, channel, admin, &sha256).await;

    let swept = s.sweep_message_retention().await.unwrap();
    assert_eq!(swept.pruned.len(), 2);
    let freed: Vec<String> = swept
        .pruned
        .iter()
        .flat_map(|p| p.freed_attachments.clone())
        .collect();
    assert_eq!(
        freed,
        vec![slimm_server::media::to_hex(&sha256)],
        "an attachment two pruned messages shared is freed exactly once"
    );
    assert!(s.attachment_summary(&sha256).await.unwrap().is_none());
}

#[tokio::test]
async fn an_attachment_a_surviving_message_still_holds_is_not_freed() {
    let (s, pool, _guard) = harness("slimm-retention-survivor-attach").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    s.set_message_retention_days(30).await.unwrap();

    let sha256 = vec![5u8; 32];
    s.store_attachment(&sha256, 1_000, "image/png", "kept.png", Some(admin))
        .await
        .unwrap();
    send_old(&s, &pool, channel, admin, &sha256).await;
    // A recent message keeps a reference the sweep must not reclaim under.
    s.send_message(NewMessage {
        channel_id: channel,
        author_id: admin,
        id: MessageId::generate(),
        content: "recent",
        attachment_ids: std::slice::from_ref(&sha256),
        spoiler_ids: &[],
        reply_to_id: None,
        forward: None,
    })
    .await
    .unwrap();

    let swept = s.sweep_message_retention().await.unwrap();
    assert_eq!(swept.pruned.len(), 1);
    let freed: Vec<String> = swept
        .pruned
        .iter()
        .flat_map(|p| p.freed_attachments.clone())
        .collect();
    assert!(
        freed.is_empty(),
        "a still-referenced attachment must not be freed"
    );
    assert!(s.attachment_summary(&sha256).await.unwrap().is_some());
}

#[tokio::test]
async fn a_byte_a_live_canvas_object_holds_is_not_freed_and_the_sweep_survives() {
    let (s, pool, _guard) = harness("slimm-retention-canvas-attach").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    s.set_message_retention_days(30).await.unwrap();

    let sha256 = vec![3u8; 32];
    s.store_attachment(&sha256, 1_000, "image/png", "pasted.png", Some(admin))
        .await
        .unwrap();
    // An old message links the byte and will be pruned.
    send_old(&s, &pool, channel, admin, &sha256).await;
    // A live canvas object holds the same byte; without the three-way check the DELETE fails the canvas FK and aborts the sweep.
    s.place_canvas_object(
        channel,
        admin,
        CanvasObjectId::generate(),
        PlaceRequest {
            kind: "image",
            bounds: (0.0, 0.0, 32.0, 32.0),
            props: r#"{"content_type":"image/png"}"#,
            attachment: Some(&sha256),
        },
    )
    .await
    .unwrap();

    let swept = s.sweep_message_retention().await.unwrap();
    assert_eq!(swept.pruned.len(), 1);
    let freed: Vec<String> = swept
        .pruned
        .iter()
        .flat_map(|p| p.freed_attachments.clone())
        .collect();
    assert!(
        freed.is_empty(),
        "a byte a live canvas object still holds must not be freed"
    );
    assert!(s.attachment_summary(&sha256).await.unwrap().is_some());
}
