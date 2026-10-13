// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a refused emoji leaves behind, which must be nothing.
//!
//! `add_emoji` writes the blob and its `attachments` row before it can know
//! whether the emoji is allowed, so a refusal used to persist an image nothing
//! referenced: bytes on disk under a content hash no row named, and a row no
//! emoji and no message pointed at. Both refusals a caller can actually
//! provoke are covered here, at exactly the cap and on a name collision, and
//! both assert the attachment row count and the blob file count rather than
//! the emoji count, because the emoji count was always right.

use sha2::{Digest, Sha256};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::emoji::{self, AddError};
use slimm_server::ids::EmojiId;
use slimm_server::media::Media;
use slimm_server::store::{MAX_CUSTOM_EMOJI, Store};
use sqlx::SqlitePool;

mod support;

// --- Fixtures ---

async fn pool() -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-emoji-refusal");
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

/// A media handle plus the directory its blobs land in, so a test can count
/// the files as well as the rows.
fn media_for_test() -> (Media, std::path::PathBuf, support::TestDirGuard) {
    let (root, guard) = support::TestDirGuard::new("slimm-emoji-refusal-media");
    let media = Media::new(&root, 10 * 1024 * 1024).expect("create temp media directories");
    (media, root.join("attachments"), guard)
}

/// A small PNG; the tail is filler, and varying it is how two "different images" are made.
fn png(filler: &[u8]) -> Vec<u8> {
    let mut bytes = support::images::small_png();
    bytes.extend_from_slice(filler);
    bytes
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

async fn attachment_count(pool: &SqlitePool) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM attachments")
        .fetch_one(pool)
        .await
        .expect("count attachments")
}

fn blob_count(dir: &std::path::Path) -> usize {
    std::fs::read_dir(dir)
        .expect("read the blob directory")
        .count()
}

// --- Tests ---

/// At exactly the cap, the refused image is never written at all.
///
/// The cap is checked before the bytes are, so the file and its row are the
/// evidence: before the fix both existed after a `Full`, referenced by
/// nothing, and only the emoji count looked right.
#[tokio::test]
async fn an_emoji_refused_at_the_cap_leaves_no_bytes_and_no_row() {
    let (pool, _guard) = pool().await;
    let store = Store::new(pool.clone());
    let (media, blobs, _mediadir) = media_for_test();

    // One attachment row, many names: the cap counts emoji, and the bytes are
    // content-addressed, so this seeds the limit without 500 blobs.
    let seed = png(b"seed");
    let seed_sha = Sha256::digest(&seed).to_vec();
    store
        .store_attachment(&seed_sha, seed.len() as i64, "image/png", "seed.img", None)
        .await
        .expect("seed the attachment row");
    for index in 0..MAX_CUSTOM_EMOJI {
        store
            .create_custom_emoji(
                EmojiId::generate(),
                &format!("seed{index}"),
                &seed_sha,
                None,
            )
            .await
            .expect("seed")
            .expect("under the cap");
    }
    assert_eq!(attachment_count(&pool).await, 1);
    assert_eq!(blob_count(&blobs), 0);

    let refused = png(b"one too many");
    let refused_sha = Sha256::digest(&refused).to_vec();
    let err = emoji::add_emoji(&store, &media, "one_too_many", refused.clone(), None)
        .await
        .expect_err("the deployment is at the cap");
    assert!(matches!(err, AddError::Full), "{err:?}");

    assert_eq!(
        attachment_count(&pool).await,
        1,
        "a refused emoji leaves no attachments row"
    );
    assert_eq!(
        blob_count(&blobs),
        0,
        "a refused emoji leaves no bytes on disk"
    );
    assert!(
        !blobs.join(hex(&refused_sha)).exists(),
        "the refused image is not stored under its own hash"
    );
    assert_eq!(
        store.list_custom_emoji().await.expect("list").len() as i64,
        MAX_CUSTOM_EMOJI,
        "at the cap, never over it"
    );
}

/// A name collision keeps the emoji that already answers to that name, and
/// stores nothing for the one that lost.
///
/// The bytes differ from the existing emoji's, so the surviving row and the
/// surviving file are provably the first upload's rather than a deduplicated
/// second copy of the same image.
#[tokio::test]
async fn an_emoji_refused_for_its_name_leaves_no_bytes_and_no_row() {
    let (pool, _guard) = pool().await;
    let store = Store::new(pool.clone());
    let (media, blobs, _mediadir) = media_for_test();

    let kept = png(b"the first party parrot");
    let kept_sha = Sha256::digest(&kept).to_vec();
    emoji::add_emoji(&store, &media, "party", kept.clone(), None)
        .await
        .expect("the first upload of this name is accepted");
    assert_eq!(attachment_count(&pool).await, 1);
    assert_eq!(blob_count(&blobs), 1);

    let loser = png(b"a different party parrot");
    let loser_sha = Sha256::digest(&loser).to_vec();
    assert_ne!(
        kept_sha, loser_sha,
        "the two images are genuinely different"
    );

    let err = emoji::add_emoji(&store, &media, "Party", loser.clone(), None)
        .await
        .expect_err("the name is taken, however it is spelled");
    assert!(matches!(err, AddError::NameTaken), "{err:?}");

    assert_eq!(
        attachment_count(&pool).await,
        1,
        "the refused image adds no attachments row"
    );
    assert_eq!(
        blob_count(&blobs),
        1,
        "the refused image adds no file to the blob directory"
    );
    assert!(
        blobs.join(hex(&kept_sha)).exists(),
        "the image members already recognise is untouched"
    );
    assert!(
        !blobs.join(hex(&loser_sha)).exists(),
        "the refused image is not stored under its own hash"
    );

    let listed = store.list_custom_emoji().await.expect("list");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].sha256, hex(&kept_sha));
}
