// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The paths where a file does not become an emoji and the report has to say
//! why: not an image, an extension that lies, an allowlisted type that is not
//! an image, and a filename that is legal but too long.

use slimm_server::emoji::MAX_NAME_LEN;
use slimm_server::emoji::import::{Outcome, Refusal, import_directory};

use crate::emoji_import::fixtures::*;

/// A file that is not an image at all is refused with a reason, and does not
/// stop the rest of the directory. A subdirectory is reported too, rather
/// than being descended into or silently dropped.
#[tokio::test]
async fn a_non_image_is_refused_and_the_rest_of_the_directory_carries_on() {
    let (store, _guard) = new_store().await;
    let (media, _mediadir) = media_for_test();
    let (dir, _packdir) = pack_dir();
    write(&dir, "readme.txt", b"read me first");
    write(&dir, "zwave.png", &png(b"wave"));
    std::fs::create_dir(dir.join("nested")).expect("create a subdirectory");

    let report = import_directory(&store, &media, &dir)
        .await
        .expect("import");

    assert_eq!(
        outcomes(&report),
        vec![
            (
                "nested".to_owned(),
                Outcome::Refused {
                    reason: Refusal::NotAFile
                }
            ),
            (
                "readme.txt".to_owned(),
                Outcome::Refused {
                    reason: Refusal::NotAnImage
                }
            ),
            (
                "zwave.png".to_owned(),
                Outcome::Imported {
                    name: "zwave".to_owned()
                }
            ),
        ]
    );
    assert_eq!(store.list_custom_emoji().await.expect("list").len(), 1);
}

/// The content type comes from the bytes. A zip named `.png` is refused, and
/// nothing about the filename gets a say.
#[tokio::test]
async fn an_extension_that_lies_about_the_content_is_refused() {
    let (store, _guard) = new_store().await;
    let (media, _mediadir) = media_for_test();
    let (dir, _packdir) = pack_dir();
    write(&dir, "sneaky.png", b"PK\x03\x04\x14\x00\x00\x00zip payload");

    let report = import_directory(&store, &media, &dir)
        .await
        .expect("import");

    assert_eq!(
        outcomes(&report),
        vec![(
            "sneaky.png".to_owned(),
            Outcome::Refused {
                reason: Refusal::NotAnImage
            }
        )]
    );
    assert!(
        store.list_custom_emoji().await.expect("list").is_empty(),
        "a zip never becomes an emoji, whatever it is called"
    );
}

/// PDF is on the upload allowlist and is the one entry on it that is not an
/// image. An emoji is drawn inline at text size, so the emoji path takes the
/// inline subset only and refuses this even though the same bytes would be
/// accepted as a message attachment.
#[tokio::test]
async fn an_allowlisted_type_that_is_not_an_image_is_refused() {
    let (store, _guard) = new_store().await;
    let (media, blob_dir, _mediadir) = media_with_blobs();
    let (dir, _packdir) = pack_dir();
    let pdf = b"%PDF-1.7\n1 0 obj\n<< >>\nendobj\n";
    write(&dir, "manual.pdf", pdf);

    // Not a fixture that merely fails to sniff, which is what the zip and the
    // text file already cover. This one sniffs to a type the server stores.
    assert_eq!(
        slimm_server::media::sniff_content_type(pdf),
        Some("application/pdf"),
        "the fixture has to reach the inline check to exercise it"
    );

    let report = import_directory(&store, &media, &dir)
        .await
        .expect("import");

    assert_eq!(
        outcomes(&report),
        vec![(
            "manual.pdf".to_owned(),
            Outcome::Refused {
                reason: Refusal::NotAnImage
            }
        )]
    );
    assert!(store.list_custom_emoji().await.expect("list").is_empty());
    assert_eq!(
        stored(&store, &blob_dir, pdf).await,
        (false, false),
        "a refused file leaves neither bytes nor a row behind"
    );
}
/// A filename of legal characters that is simply long is refused for its
/// length, not for its characters. Downloaded packs name files that way as a
/// matter of course, and "no usable name (a-z, 0-9 or _)" would send whoever
/// reads it hunting for an illegal character that is not there.
#[tokio::test]
async fn a_long_filename_is_refused_for_its_length_not_its_characters() {
    let (store, _guard) = new_store().await;
    let (media, _mediadir) = media_for_test();
    let (dir, _packdir) = pack_dir();

    let long = "a".repeat(MAX_NAME_LEN + 1);
    write(&dir, &format!("{long}.png"), &png(b"long"));
    write(&dir, "!!!.png", &png(b"unusable"));

    let report = import_directory(&store, &media, &dir)
        .await
        .expect("import");

    assert_eq!(
        outcomes(&report),
        vec![
            (
                "!!!.png".to_owned(),
                Outcome::Refused {
                    reason: Refusal::UnusableName
                }
            ),
            (
                format!("{long}.png"),
                Outcome::Refused {
                    reason: Refusal::NameTooLong {
                        length: MAX_NAME_LEN + 1
                    }
                }
            ),
        ]
    );

    // The rendered report is what an operator actually reads, so the two
    // reasons have to differ there and not only as variants.
    let rendered = report.to_string();
    assert!(
        rendered.contains("33 characters, over the 32 character limit"),
        "the long name is refused by length: {rendered}"
    );
    assert!(
        rendered.contains("leaves no usable name"),
        "the unusable one still says so: {rendered}"
    );
    assert!(store.list_custom_emoji().await.expect("list").is_empty());
}
