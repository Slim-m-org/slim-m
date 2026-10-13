// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The paths where a file does become an emoji: a clean run, a re-run over the
//! same directory, and a name already taken by a different image.

use sha2::{Digest, Sha256};
use slimm_server::emoji;
use slimm_server::emoji::import::{Outcome, import_directory};

use crate::fixtures::*;

// --- Tests ---

/// Every image in the directory becomes an emoji named after its filename,
/// through the same normaliser an upload goes through, with its bytes in the
/// content-addressed blob an upload would have written.
#[tokio::test]
async fn a_clean_import_adds_every_image_under_its_normalised_name() {
    let (store, _guard) = new_store().await;
    let (media, _mediadir) = media_for_test();
    let (dir, _packdir) = pack_dir();

    let smile = png(b"smile");
    write(&dir, "Big Smile.png", &smile);
    write(
        &dir,
        "party-parrot.gif",
        &crate::support::images::animated_gif(),
    );
    write(&dir, "okay.jpg", &crate::support::images::small_jpeg());

    let report = import_directory(&store, &media, &dir)
        .await
        .expect("import");

    assert_eq!(
        outcomes(&report),
        vec![
            (
                "Big Smile.png".to_owned(),
                Outcome::Imported {
                    name: "big_smile".to_owned()
                }
            ),
            (
                "okay.jpg".to_owned(),
                Outcome::Imported {
                    name: "okay".to_owned()
                }
            ),
            (
                "party-parrot.gif".to_owned(),
                Outcome::Imported {
                    name: "party_parrot".to_owned()
                }
            ),
        ]
    );
    assert!(report.is_clean(), "nothing was left out");

    let stored = store.list_custom_emoji().await.expect("list");
    assert_eq!(stored.len(), 3);
    let names: Vec<&str> = stored.iter().map(|e| e.name.as_str()).collect();
    assert!(names.contains(&"big_smile") && names.contains(&"party_parrot"));

    // The one normaliser, not a second one that happens to agree today.
    assert_eq!(
        emoji::normalize_name("Big Smile").as_deref(),
        Ok("big_smile")
    );

    // Requirement 3: the bytes are in the blob the HTTP upload writes to,
    // reachable by the same content hash.
    let entry = stored
        .iter()
        .find(|e| e.name == "big_smile")
        .expect("the imported emoji");
    let bytes = media
        .read_attachment(&entry.sha256)
        .await
        .expect("read the emoji's blob back");
    assert_eq!(bytes, smile);
    assert_eq!(
        entry.sha256,
        slimm_server::media::to_hex(&Sha256::digest(&smile))
    );

    // Nobody uploaded it, so there is no account to attribute it to.
    assert!(entry.uploader_id.is_none());
}

/// Re-running an import over the same directory is a no-op, not a pile of
/// duplicates and not an error.
#[tokio::test]
async fn re_importing_the_same_directory_changes_nothing() {
    let (store, _guard) = new_store().await;
    let (media, _mediadir) = media_for_test();
    let (dir, _packdir) = pack_dir();
    write(&dir, "my_smile.png", &png(b"smile"));
    write(&dir, "my_wave.png", &png(b"wave"));

    let first = import_directory(&store, &media, &dir)
        .await
        .expect("import");
    assert_eq!(first.settled(), 2);

    let second = import_directory(&store, &media, &dir)
        .await
        .expect("re-import");

    assert_eq!(
        outcomes(&second),
        vec![
            (
                "my_smile.png".to_owned(),
                Outcome::Unchanged {
                    name: "my_smile".to_owned()
                }
            ),
            (
                "my_wave.png".to_owned(),
                Outcome::Unchanged {
                    name: "my_wave".to_owned()
                }
            ),
        ]
    );
    assert!(second.is_clean(), "a re-run is a success, not a failure");
    assert_eq!(store.list_custom_emoji().await.expect("list").len(), 2);
}

/// A name already in use by a different image is skipped, and the image
/// members already know stays live.
#[tokio::test]
async fn a_name_collision_skips_rather_than_replacing_the_existing_image() {
    let (store, _guard) = new_store().await;
    let (media, _mediadir) = media_for_test();

    let original = png(b"the original");
    let (first_dir, _firstpack) = pack_dir();
    write(&first_dir, "my_smile.png", &original);
    import_directory(&store, &media, &first_dir)
        .await
        .expect("first import");

    let (second_dir, _secondpack) = pack_dir();
    write(
        &second_dir,
        "My_Smile.png",
        &png(b"a completely different image"),
    );
    let report = import_directory(&store, &media, &second_dir)
        .await
        .expect("second import");

    assert_eq!(
        outcomes(&report),
        vec![(
            "My_Smile.png".to_owned(),
            Outcome::NameTaken {
                name: "my_smile".to_owned()
            }
        )]
    );
    assert!(!report.is_clean(), "a skipped file is not a clean run");

    let stored = store.list_custom_emoji().await.expect("list");
    assert_eq!(stored.len(), 1, "no duplicate under the same name");
    assert_eq!(
        stored[0].sha256,
        slimm_server::media::to_hex(&Sha256::digest(&original)),
        "the original image is still the one :smile: points at"
    );
}
