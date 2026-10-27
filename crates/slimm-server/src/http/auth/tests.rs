// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `everyone`/`here` are refused case-insensitively, and a name that
/// merely contains one as a substring is untouched - only the reserved
/// word itself is off limits.
#[test]
fn reserved_mention_words_are_refused_as_usernames_case_insensitively() {
    assert!(super::validate_username("everyone").is_err());
    assert!(super::validate_username("Everyone").is_err());
    assert!(super::validate_username("HERE").is_err());
    assert!(super::validate_username("everyone1").is_ok());
    assert!(super::validate_username("not-here").is_ok());
}

/// The length rule is inclusive at both ends: empty is refused, one
/// character is enough, thirty-two is the ceiling, and thirty-three is
/// over it.
#[test]
fn a_username_must_be_one_to_thirty_two_characters() {
    assert!(super::validate_username("").is_err());
    assert!(super::validate_username("a").is_ok());
    assert!(super::validate_username(&"a".repeat(32)).is_ok());
    assert!(super::validate_username(&"a".repeat(33)).is_err());
}

/// Only ASCII letters, digits and `_ . -` pass; a space, an `@`, a
/// non-ASCII letter, and other punctuation are each refused, so a username
/// can never carry a character a mention or a path would then have to
/// escape. Length is checked first, so every case here is short enough to
/// reach the character rule.
#[test]
fn a_username_allows_only_letters_digits_and_a_few_marks() {
    assert!(super::validate_username("aZ09_.-").is_ok());
    for bad in [
        "has space",
        "has@at",
        "café",
        "bang!",
        "slash/here",
        "colon:",
    ] {
        assert!(super::validate_username(bad).is_err(), "{bad:?}");
    }
}

/// A display label allows the unicode a username cannot - letters of any
/// script, spaces, emoji - and is bounded 1 to 64 characters. A name that
/// is only whitespace passes the length check but is refused as blank.
#[test]
fn a_display_label_is_bounded_and_may_not_be_only_whitespace() {
    let msg = "label bad";
    assert!(super::validate_label("A", msg).is_ok());
    assert!(super::validate_label("José 日本語 🎉", msg).is_ok());
    assert!(super::validate_label(&"a".repeat(64), msg).is_ok());
    assert!(super::validate_label("", msg).is_err());
    assert!(super::validate_label(&"a".repeat(65), msg).is_err());
    assert!(super::validate_label("   ", msg).is_err());
}

/// The one thing a display label cannot carry: control characters, and the
/// zero-width and bidi-override characters a name would otherwise use to
/// spoof how it renders (the right-to-left override is the classic one).
#[test]
fn a_display_label_refuses_control_and_direction_characters() {
    let msg = "label bad";
    for bad in [
        "a\nb",
        "a\u{202E}b",
        "a\u{200B}b",
        "a\u{FEFF}b",
        "a\u{2066}b",
    ] {
        assert!(super::validate_label(bad, msg).is_err(), "{bad:?}");
    }
}

/// The password length rule itself, not only its wording: inclusive 8 to
/// 1024, counted by character.
#[test]
fn a_password_must_be_eight_to_1024_characters() {
    assert!(super::validate_password(&"a".repeat(7)).is_err());
    assert!(super::validate_password(&"a".repeat(8)).is_ok());
    assert!(super::validate_password(&"a".repeat(1024)).is_ok());
    assert!(super::validate_password(&"a".repeat(1025)).is_err());
}

/// Cross-checked against the same string in `client/packages/app/test/
/// support/onboarding_error_strings.dart`, both read from `tests/
/// fixtures/onboarding_error_strings.json` - editing the length rule's
/// wording on one side without the other fails whichever side the
/// fixture no longer matches.
#[test]
fn password_length_message_matches_the_shared_onboarding_fixture() {
    let fixture = load_fixture();
    assert_eq!(
        super::validation::PASSWORD_LENGTH_MESSAGE,
        fixture.password_length_error
    );
}

#[derive(serde::Deserialize)]
struct OnboardingErrorStrings {
    password_length_error: String,
}

fn load_fixture() -> OnboardingErrorStrings {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/onboarding_error_strings.json");
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    serde_json::from_str(&raw).expect("onboarding_error_strings.json must be valid JSON")
}
