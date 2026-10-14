// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The orphaned-attachment sweep, and the custom emoji that sits in front of
//! it.
//!
//! An emoji's image is an `attachments` row nothing ever attached to a
//! message, which is exactly the shape the sweep hunts, and
//! `0016_custom_emoji.sql` guards it with `ON DELETE RESTRICT`. RESTRICT is
//! not a filter: it aborts the whole `DELETE`, so a single emoji stopped the
//! sweep for the entire deployment and no orphan was ever reclaimed again.
//! The sweep has to exclude an emoji's bytes itself.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{CanvasObjectId, EmojiId};
use slimm_server::store::{NewMessage, PlaceRequest, Store};
use sqlx::SqlitePool;

mod support;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

async fn pool() -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-attachment-sweep");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    (
        db::connect(&config).await.expect("connect + migrate"),
        guard,
    )
}

/// Drags every attachment's `created_at` back past the sweep's grace window,
/// standing in for an upload made that long ago without making the test wait.
async fn age_attachments(pool: &SqlitePool) {
    sqlx::query("UPDATE attachments SET created_at = created_at - ?")
        .bind(2 * DAY_MS)
        .execute(pool)
        .await
        .expect("age attachments");
}

async fn attachment_count(pool: &SqlitePool) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM attachments")
        .fetch_one(pool)
        .await
        .expect("count attachments")
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Control: with no emoji anywhere, one aged upload nobody attached is
/// reclaimed. This is the behaviour the emoji case must not change.
#[tokio::test]
async fn an_aged_unattached_upload_is_swept() {
    let (pool, _guard) = pool().await;
    let store = Store::new(pool.clone());

    let orphan = [0xAAu8; 32];
    store
        .store_attachment(&orphan, 8, "image/png", "orphan.png", None)
        .await
        .unwrap();
    age_attachments(&pool).await;

    let freed = store.sweep_orphaned_attachments().await.unwrap();
    assert_eq!(freed, vec![hex(&orphan)]);
    assert_eq!(attachment_count(&pool).await, 0);
}

/// The regression. A deployment holding one custom emoji must still reclaim a
/// genuine orphan, and must keep the emoji's bytes while doing it.
///
/// Before the fix the emoji's row was itself a delete candidate, RESTRICT
/// aborted the statement, and `sweep_orphaned_attachments` returned an error
/// with the orphan still on disk: attachment garbage collection stopped for
/// the life of the deployment.
#[tokio::test]
async fn an_emoji_does_not_stop_the_sweep_and_its_bytes_survive() {
    let (pool, _guard) = pool().await;
    let store = Store::new(pool.clone());

    let emoji_bytes = [0x11u8; 32];
    let orphan = [0x22u8; 32];
    store
        .store_attachment(&emoji_bytes, 8, "image/png", "party.png", None)
        .await
        .unwrap();
    store
        .store_attachment(&orphan, 8, "image/png", "orphan.png", None)
        .await
        .unwrap();
    store
        .create_custom_emoji(EmojiId::generate(), "party", &emoji_bytes, None)
        .await
        .unwrap()
        .expect("the emoji is created");
    age_attachments(&pool).await;

    let freed = store
        .sweep_orphaned_attachments()
        .await
        .expect("an emoji must not fail the sweep");
    assert_eq!(
        freed,
        vec![hex(&orphan)],
        "the genuine orphan is reclaimed and the emoji's bytes are not"
    );

    let kept: Option<Vec<u8>> = sqlx::query_scalar("SELECT sha256 FROM attachments")
        .fetch_optional(&pool)
        .await
        .unwrap();
    assert_eq!(
        kept.as_deref(),
        Some(emoji_bytes.as_slice()),
        "the emoji's row is the only attachment left"
    );

    // The emoji itself still resolves, so the RESTRICT it relies on was never
    // reached rather than merely tolerated.
    let listed = store.list_custom_emoji().await.unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].sha256, hex(&emoji_bytes));
}

/// Deleting the emoji makes its bytes an ordinary orphan again, so the space
/// is genuinely reclaimable rather than pinned forever by the exclusion.
#[tokio::test]
async fn removing_the_emoji_releases_its_bytes_to_the_next_sweep() {
    let (pool, _guard) = pool().await;
    let store = Store::new(pool.clone());

    let emoji_bytes = [0x33u8; 32];
    store
        .store_attachment(&emoji_bytes, 8, "image/png", "party.png", None)
        .await
        .unwrap();
    let id = EmojiId::generate();
    store
        .create_custom_emoji(id, "party", &emoji_bytes, None)
        .await
        .unwrap()
        .expect("the emoji is created");
    age_attachments(&pool).await;

    assert!(store.sweep_orphaned_attachments().await.unwrap().is_empty());
    assert!(store.delete_custom_emoji(id).await.unwrap());

    let freed = store.sweep_orphaned_attachments().await.unwrap();
    assert_eq!(freed, vec![hex(&emoji_bytes)]);
    assert_eq!(attachment_count(&pool).await, 0);
}

/// A pasted canvas image is never attached to a message at all - the same
/// blind spot an emoji's own bytes are, and the same fix: excluding
/// `canvas_object_attachments` in the sweep's own `NOT EXISTS` clauses, not
/// relying on a `RESTRICT` this table deliberately does not carry (a canvas
/// object is only ever soft-deleted, so its attachment link must survive a
/// restore, which `ON DELETE RESTRICT` cannot express).
#[tokio::test]
async fn a_canvas_placement_does_not_stop_the_sweep_and_its_bytes_survive() {
    let (pool, _guard) = pool().await;
    let store = Store::new(pool.clone());

    let pasted = [0x44u8; 32];
    let orphan = [0x55u8; 32];
    let author = store
        .create_account("ann", "Ann", "hash")
        .await
        .expect("an author")
        .id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    store
        .store_attachment(&pasted, 8, "image/png", "pasted.png", Some(author))
        .await
        .unwrap();
    store
        .store_attachment(&orphan, 8, "image/png", "orphan.png", None)
        .await
        .unwrap();
    store
        .place_canvas_object(
            channel,
            author,
            CanvasObjectId::generate(),
            PlaceRequest {
                kind: "image",
                bounds: (0.0, 0.0, 10.0, 10.0),
                props: r#"{"attachment":"aaaa"}"#,
                attachment: Some(&pasted),
            },
        )
        .await
        .expect("the placement is authorized: the caller uploaded these bytes");
    age_attachments(&pool).await;

    let freed = store
        .sweep_orphaned_attachments()
        .await
        .expect("a canvas placement must not fail the sweep");
    assert_eq!(
        freed,
        vec![hex(&orphan)],
        "the genuine orphan is reclaimed and the pasted image's bytes are not"
    );

    let kept: Option<Vec<u8>> = sqlx::query_scalar("SELECT sha256 FROM attachments")
        .fetch_optional(&pool)
        .await
        .unwrap();
    assert_eq!(
        kept.as_deref(),
        Some(pasted.as_slice()),
        "the canvas image's row is the only attachment left"
    );
}

/// Deleting a message whose image is ALSO a custom emoji must not fail.
///
/// Content addressing makes this collision the normal case rather than an
/// exotic one: `add_emoji` deliberately reuses an `attachments` row someone
/// already attached to a message, and the import path advertises that as the
/// reason an image costs one copy. `release_message_attachments` then deletes
/// the row once no *message* references the hash, which is the same blind spot
/// the sweep had - RESTRICT aborts the delete and takes the whole
/// message-deletion transaction with it.
#[tokio::test]
async fn deleting_a_message_whose_image_is_also_an_emoji_still_works() {
    use slimm_server::ids::MessageId;

    let (pool, _guard) = pool().await;
    let store = Store::new(pool.clone());

    let shared = [0x33u8; 32];
    let channel = store.create_channel("general", "text").await.unwrap();
    let author = store
        .create_account("alice", "Alice", "hash")
        .await
        .expect("an author")
        .id;
    store
        .store_attachment(&shared, 8, "image/png", "shared.png", Some(author))
        .await
        .unwrap();

    let message = MessageId::generate();
    store
        .send_message(NewMessage {
            channel_id: channel.id,
            author_id: author,
            id: message,
            content: "look at this",
            attachment_ids: &[shared.to_vec()],
            spoiler_ids: &[],
            reply_to_id: None,
            forward: None,
        })
        .await
        .expect("the message is sent with its attachment");

    store
        .create_custom_emoji(EmojiId::generate(), "shared", &shared, None)
        .await
        .unwrap()
        .expect("the emoji reuses the message's bytes");

    let deletion = store
        .delete_message(message, author)
        .await
        .expect("an emoji sharing the bytes must not fail the delete");

    assert!(
        deletion.freed_attachments.is_empty(),
        "the bytes are still an emoji's, so nothing may be freed: {:?}",
        deletion.freed_attachments
    );
    assert_eq!(
        attachment_count(&pool).await,
        1,
        "the emoji's row must survive the message that shared it"
    );
    assert!(
        store
            .custom_emoji_sha256_by_name("shared")
            .await
            .unwrap()
            .is_some(),
        "the emoji must still resolve to its bytes"
    );
}
