// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The two ceilings: one megabyte per image, and five hundred emoji per
//! deployment.

use sha2::{Digest, Sha256};
use slimm_server::emoji;
use slimm_server::emoji::MAX_IMAGE_BYTES;
use slimm_server::emoji::import::{Outcome, Refusal, import_directory};
use slimm_server::ids::EmojiId;
use slimm_server::store::MAX_CUSTOM_EMOJI;

use crate::emoji_import::fixtures::*;

/// A file over the one megabyte ceiling is refused, and the report says how
/// big it actually was. The ceiling is a documented limit and the only bound
/// on how much an arbitrary directory can be made to read.
#[tokio::test]
async fn a_file_over_the_size_ceiling_is_refused() {
    let (store, _guard) = new_store().await;
    let (media, blob_dir, _mediadir) = media_with_blobs();
    let (dir, _packdir) = pack_dir();

    let oversized = png(&vec![0u8; MAX_IMAGE_BYTES as usize]);
    write(&dir, "huge.png", &oversized);
    write(&dir, "my_wave.png", &png(b"wave"));

    let report = import_directory(&store, &media, &dir)
        .await
        .expect("import");

    assert_eq!(
        outcomes(&report),
        vec![
            (
                "huge.png".to_owned(),
                Outcome::Refused {
                    reason: Refusal::TooLarge {
                        bytes: oversized.len() as u64
                    }
                }
            ),
            (
                "my_wave.png".to_owned(),
                Outcome::Imported {
                    name: "my_wave".to_owned()
                }
            ),
        ]
    );
    assert_eq!(
        stored(&store, &blob_dir, &oversized).await,
        (false, false),
        "nothing over the ceiling reaches storage"
    );
    assert_eq!(blobs(&blob_dir).len(), 1, "only the one that fit");
}

/// The size is taken from the directory entry, before the file is opened, so
/// an enormous file is refused without being pulled into memory first. Its
/// name is unusable too: with the on-disk check gone the name is what the
/// import would reach first, and it would say so.
#[tokio::test]
async fn the_size_is_read_from_disk_rather_than_from_the_bytes() {
    let (store, _guard) = new_store().await;
    let (media, _mediadir) = media_for_test();
    let (dir, _packdir) = pack_dir();

    let oversized = png(&vec![0u8; MAX_IMAGE_BYTES as usize]);
    write(&dir, "!!!.png", &oversized);

    let report = import_directory(&store, &media, &dir)
        .await
        .expect("import");

    assert_eq!(
        outcomes(&report),
        vec![(
            "!!!.png".to_owned(),
            Outcome::Refused {
                reason: Refusal::TooLarge {
                    bytes: oversized.len() as u64
                }
            }
        )]
    );
}

/// The same ceiling holds for whatever calls [`emoji::add_emoji`] without
/// going through the import at all, which is the HTTP upload.
#[tokio::test]
async fn add_emoji_refuses_bytes_over_the_ceiling_on_its_own() {
    let (store, _guard) = new_store().await;
    let (media, blob_dir, _mediadir) = media_with_blobs();

    let oversized = png(&vec![0u8; MAX_IMAGE_BYTES as usize]);
    let err = emoji::add_emoji(&store, &media, "huge", oversized.clone(), None)
        .await
        .expect_err("over the ceiling");

    assert!(
        matches!(err, emoji::AddError::TooLarge),
        "expected TooLarge, got {err:?}"
    );
    assert_eq!(stored(&store, &blob_dir, &oversized).await, (false, false));
}
/// Hitting the cap mid-import reports exactly what did not fit, keeps what
/// did, and leaves the deployment at the cap rather than over it.
///
/// Once the cap is reached the import stops looking at files, so everything
/// after it is reported as not fitting rather than for some property of its
/// own: `notes.txt` is here to be a file the import would otherwise have had
/// an opinion about, and `d.png` to be one more after that. Without the latch
/// each of them is attempted again, which is both a directory's worth of
/// wasted reads and a report that blames the wrong thing.
#[tokio::test]
async fn hitting_the_cap_reports_what_was_left_out_and_keeps_the_rest() {
    let (store, _guard) = new_store().await;
    let (media, blob_dir, _mediadir) = media_with_blobs();

    // One attachment row, many names: the cap counts emoji, and the bytes
    // are content-addressed, so this seeds the limit without 499 blobs.
    let seed = png(b"seed");
    let sha = Sha256::digest(&seed).to_vec();
    store
        .store_attachment(&sha, seed.len() as i64, "image/png", "seed.img", None)
        .await
        .expect("seed the attachment row");
    for index in 0..MAX_CUSTOM_EMOJI - 1 {
        store
            .create_custom_emoji(EmojiId::generate(), &format!("seed{index}"), &sha, None)
            .await
            .expect("seed")
            .expect("under the cap");
    }

    let (dir, _packdir) = pack_dir();
    write(&dir, "aa.png", &png(b"a"));
    write(&dir, "bb.png", &png(b"b"));
    write(&dir, "dd.png", &png(b"d"));
    write(&dir, "notes.txt", b"read me first");

    let report = import_directory(&store, &media, &dir)
        .await
        .expect("import");

    assert_eq!(
        outcomes(&report),
        vec![
            (
                "aa.png".to_owned(),
                Outcome::Imported {
                    name: "aa".to_owned()
                }
            ),
            ("bb.png".to_owned(), Outcome::AtCapacity),
            ("dd.png".to_owned(), Outcome::AtCapacity),
            ("notes.txt".to_owned(), Outcome::AtCapacity),
        ]
    );
    assert_eq!(report.unimported(), 3);
    assert!(!report.is_clean());

    let catalog = store.list_custom_emoji().await.expect("list");
    assert_eq!(
        catalog.len() as i64,
        MAX_CUSTOM_EMOJI,
        "at the cap, never over it"
    );
    assert!(
        catalog.iter().any(|e| e.name == "aa"),
        "what fit before the cap stays imported"
    );

    // Nothing past the cap writes bytes or a row: a full deployment is not a
    // way to fill the blob directory one orphan per file.
    assert_eq!(
        blobs(&blob_dir),
        vec![slimm_server::media::to_hex(&Sha256::digest(png(b"a")))],
        "only the file that fit left a blob"
    );
    for refused in [png(b"b"), png(b"d")] {
        assert_eq!(stored(&store, &blob_dir, &refused).await, (false, false));
    }

    // The report says so in words, not only in variants.
    let rendered = report.to_string();
    assert!(
        rendered.contains("1 imported") && rendered.contains("3 over the limit"),
        "the summary names what was left out: {rendered}"
    );
}
