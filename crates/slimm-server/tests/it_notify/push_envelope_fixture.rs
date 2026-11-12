// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The shared fixture that keeps the iOS Notification Service Extension's
//! hand-written sealed-box implementation honest.
//!
//! The extension has to open a `crypto_box` sealed box (X25519, HSalsa20,
//! XSalsa20-Poly1305, BLAKE2b) in Swift, and none of those primitives exist in
//! CryptoKit, so `ios/NotificationService/` implements them from their specs.
//! Reasoning about that implementation is not evidence it is right, and this
//! environment has no Swift toolchain and no device to run it on, so the
//! evidence is a fixture instead: real ciphertext produced here, by the same
//! crate version the server actually seals with, opened over there by an
//! XCTest that runs on a macOS runner in `client-ios-ci`.
//!
//! Both sides read one file, the shape
//! `tests/fixtures/mention_charset_cases.json` already established for the
//! mention charset, so a one-sided change fails rather than drifting. It lives
//! under `RunnerTests/` rather than beside its sibling here because an XCTest
//! reads a resource out of its own bundle and cannot walk to the repo root;
//! this side walks to it instead, which is the direction that works.
//!
//! [`the_committed_fixture_is_a_real_sealed_box`] is the one that matters: it
//! proves the committed bytes are genuinely openable by the server's own
//! crate, so a Swift failure against them is a Swift bug rather than a
//! fabricated fixture. Regenerate with:
//!
//! ```text
//! SLIMM_REGENERATE_PUSH_FIXTURE=1 cargo test -p slimm-server \
//!     --test it_notify -- push_envelope_fixture::regenerate
//! ```
//!
//! An environment variable rather than `#[ignore]`, matching `SLIMM_GOLDENS`
//! and `SLIMM_UI_SNAPSHOTS`: every run of this rewrites a committed file with
//! different bytes, since a sealed box draws a fresh ephemeral key each time,
//! so an ordinary `cargo test` must not do it by accident.

use std::fs;
use std::path::PathBuf;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use crypto_box::SecretKey;
use crypto_box::aead::rand_core::{OsRng, TryRngCore};
use serde_json::{Value, json};

/// Walks from this crate to the Xcode test target that reads the same file.
fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../client/packages/app/ios/RunnerTests/push_envelope_cases.json")
}

fn fixture() -> Value {
    let raw = fs::read_to_string(fixture_path()).expect("the fixture is committed");
    serde_json::from_str(&raw).expect("the fixture is valid json")
}

/// Plaintexts chosen for where the arithmetic changes, not for realism alone.
///
/// XSalsa20 spends the first 32 bytes of its first keystream block on the
/// one-time Poly1305 key, so the message starts at offset 32 of block 0 and
/// crosses into block 1 at 32 bytes of plaintext, block 2 at 96, and so on. A
/// fixture made only of realistic envelopes would exercise one arm of that and
/// pass while an off-by-one-block bug shipped, so the empty, 1, 31, 32, 33, 64
/// and 96-byte cases are here deliberately - as is a multi-byte body, since a
/// Poly1305 final block is padded by byte length rather than by character.
fn plaintexts() -> Vec<(&'static str, String)> {
    let envelope = json!({
        "domain": "slim-m.push.v1",
        "version": 1,
        "kind": "message",
        "channel_id": "019fbd32-f633-7a63-a6a8-497513c44e6b",
        "message_id": "019fbd41-2c8a-7d10-9f31-6b1e4a2f80c7",
        "seq": 4291,
        "sent_at": 1_754_985_600_000_i64,
        "sender": "Ada Lovelace",
        "channel": "general",
        "body": "the analytical engine has no pretensions to originate anything",
    });
    let content_free = json!({
        "domain": "slim-m.push.v1",
        "version": 1,
        "kind": "message",
        "channel_id": "019fbd32-f633-7a63-a6a8-497513c44e6b",
        "message_id": "019fbd41-2c8a-7d10-9f31-6b1e4a2f80c7",
        "seq": 4291,
        "sent_at": 1_754_985_600_000_i64,
    });
    let dm = json!({
        "domain": "slim-m.push.v1",
        "version": 1,
        "kind": "message",
        "channel_id": "019fbd32-f633-7a63-a6a8-497513c44e6b",
        "message_id": "019fbd41-2c8a-7d10-9f31-6b1e4a2f80c7",
        "seq": 7,
        "sent_at": 1_754_985_600_000_i64,
        "sender": "\u{30a2}\u{30c0}\u{30fb}\u{30e9}\u{30d6}\u{30ec}\u{30b9}",
        "body": "\u{3053}\u{3093}\u{3070}\u{3093}\u{306f}\u{3001}\u{5143}\u{6c17}\u{3067}\u{3059}\u{304b}",
    });
    // No `sent_at`: a server built before that field existed; see PushEnvelope.swift.
    let pre_sent_at = json!({
        "domain": "slim-m.push.v1",
        "version": 1,
        "kind": "message",
        "channel_id": "019fbd32-f633-7a63-a6a8-497513c44e6b",
        "message_id": "019fbd41-2c8a-7d10-9f31-6b1e4a2f80c7",
        "seq": 12,
        "sender": "Grace Hopper",
        "body": "sealed before sent_at existed on the wire",
    });

    vec![
        ("empty", String::new()),
        ("one byte", "a".to_string()),
        ("31 bytes, one short of a block", "a".repeat(31)),
        (
            "32 bytes, exactly the first block's remainder",
            "a".repeat(32),
        ),
        ("33 bytes, one into the second block", "a".repeat(33)),
        ("64 bytes", "a".repeat(64)),
        ("96 bytes, exactly two blocks", "a".repeat(96)),
        ("a message envelope with a preview", envelope.to_string()),
        ("a content-free envelope", content_free.to_string()),
        ("a dm envelope, multi-byte throughout", dm.to_string()),
        (
            "a pre-sent_at envelope from an older server",
            pre_sent_at.to_string(),
        ),
    ]
}

/// Writes the fixture from real `crypto_box` output, when explicitly asked
/// to. See this file's own module doc for why it is asked rather than run.
#[test]
fn regenerate_the_fixture_when_asked() {
    if std::env::var_os("SLIMM_REGENERATE_PUSH_FIXTURE").is_none() {
        return;
    }

    let secret = SecretKey::generate(&mut OsRng.unwrap_err());
    let public = secret.public_key();

    let cases: Vec<Value> = plaintexts()
        .into_iter()
        .map(|(name, plaintext)| {
            let sealed = public
                .seal(&mut OsRng.unwrap_err(), plaintext.as_bytes())
                .expect("seals");
            json!({
                "name": name,
                "plaintext": plaintext,
                "sealed_base64": BASE64.encode(&sealed),
            })
        })
        .collect();

    let document = json!({
        "note": concat!(
            "Generated by crates/slimm-server/tests/it_notify/push_envelope_fixture.rs. ",
            "Read by that file and by RunnerTests/PushSealedBoxTests.swift. ",
            "Do not hand-edit: the ciphertext is real crypto_box output and ",
            "nothing here would still verify."
        ),
        "recipient_secret_key_base64": BASE64.encode(secret.to_bytes()),
        "recipient_public_key_base64": BASE64.encode(public.as_bytes()),
        "cases": cases,
    });

    let mut serialized = serde_json::to_string_pretty(&document).expect("serializes");
    serialized.push('\n');
    fs::write(fixture_path(), serialized).expect("writes the fixture");
}

/// The load-bearing one. A fixture the server's own crate cannot open is a
/// fabricated fixture, and a Swift test passing against one would prove
/// nothing at all.
#[test]
fn the_committed_fixture_is_a_real_sealed_box() {
    let fixture = fixture();
    let secret_bytes = BASE64
        .decode(fixture["recipient_secret_key_base64"].as_str().unwrap())
        .expect("the secret key is base64");
    let secret = SecretKey::from_slice(&secret_bytes).expect("32 bytes");

    let cases = fixture["cases"].as_array().expect("cases is an array");
    assert!(!cases.is_empty(), "an empty fixture would pass vacuously");

    for case in cases {
        let name = case["name"].as_str().unwrap();
        let sealed = BASE64
            .decode(case["sealed_base64"].as_str().unwrap())
            .unwrap_or_else(|_| panic!("{name}: sealed_base64 is base64"));
        let opened = secret
            .unseal(&sealed)
            .unwrap_or_else(|_| panic!("{name}: unseals with the recipient key"));
        assert_eq!(
            String::from_utf8(opened).unwrap_or_else(|_| panic!("{name}: utf8")),
            case["plaintext"].as_str().unwrap(),
            "{name}: opens to the plaintext the fixture claims"
        );
    }
}

/// The recipient key pair has to agree with itself, because the extension
/// derives the public key from the private one to rebuild the sealed box's
/// nonce - `BLAKE2b(ephemeral_public || recipient_public)`. A fixture whose
/// two halves disagreed would fail there and read as a hashing bug.
#[test]
fn the_fixtures_public_key_is_the_one_its_secret_key_derives() {
    let fixture = fixture();
    let secret_bytes = BASE64
        .decode(fixture["recipient_secret_key_base64"].as_str().unwrap())
        .expect("base64");
    let secret = SecretKey::from_slice(&secret_bytes).expect("32 bytes");

    assert_eq!(
        BASE64.encode(secret.public_key().as_bytes()),
        fixture["recipient_public_key_base64"].as_str().unwrap(),
    );
}

/// The block-boundary cases are the point of the fixture, so their absence
/// must fail rather than quietly reducing this to a happy-path check.
#[test]
fn the_fixture_still_covers_every_keystream_boundary() {
    let fixture = fixture();
    let lengths: Vec<usize> = fixture["cases"]
        .as_array()
        .unwrap()
        .iter()
        .map(|case| case["plaintext"].as_str().unwrap().len())
        .collect();

    for wanted in [0, 1, 31, 32, 33, 64, 96] {
        assert!(
            lengths.contains(&wanted),
            "no case of {wanted} bytes; see this file's own note on why each \
             boundary is here, and regenerate rather than dropping one"
        );
    }
}
