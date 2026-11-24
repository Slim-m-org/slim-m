// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Unit tests for the TOTP primitive: the parameters, the skew window, and the
//! step arithmetic the replay guard keys on.

use super::*;

/// The published RFC 6238 appendix B vector for HMAC-SHA1, truncated to the six
/// digits this deployment uses.
///
/// Pinned because the parameters are an interoperability contract with every
/// authenticator app in existence: change the digest, the digit count or the
/// step and every already-enrolled device silently starts producing codes this
/// server rejects, with nothing else in the suite to notice.
const RFC_SECRET_BASE32: &str = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

#[test]
fn matches_the_rfc_6238_sha1_vector() {
    // The first appendix B row at 59s; the RFC prints 94287082 at eight digits, so six is its low half.
    let step =
        super::matching_step(RFC_SECRET_BASE32, "287082", 59_000).expect("a valid base32 secret");
    assert_eq!(step, Some(1), "59s is step 1, and 287082 is its code");
}

#[test]
fn a_wrong_code_does_not_match() {
    assert_eq!(
        super::matching_step(RFC_SECRET_BASE32, "000000", 59_000).unwrap(),
        None
    );
}

#[test]
fn a_malformed_code_does_not_match_and_does_not_error() {
    for code in ["", "12345", "1234567", "abcdef", "  287082  "] {
        assert_eq!(
            super::matching_step(RFC_SECRET_BASE32, code, 59_000).unwrap(),
            None,
            "{code:?} should be a plain non-match"
        );
    }
}

/// One step either side, and no more. The window is the whole security budget
/// of the skew tolerance, so a change that widened it silently would be the
/// kind of regression only this asserts on.
#[test]
fn the_window_is_one_step_either_side() {
    let secret = super::generate_secret();
    let now = 1_700_000_000_000_i64;
    let here = super::step_at(now);
    let code = code_for(&secret, here);

    let ms_per_step = STEP_SECONDS as i64 * 1000;
    // A code from the previous step is still accepted a step later.
    assert_eq!(
        super::matching_step(&secret, &code, now + ms_per_step).unwrap(),
        Some(here)
    );
    // And one from the next step is accepted a step early.
    assert_eq!(
        super::matching_step(&secret, &code, now - ms_per_step).unwrap(),
        Some(here)
    );
    // Two steps out, in either direction, is refused.
    assert_eq!(
        super::matching_step(&secret, &code, now + 2 * ms_per_step).unwrap(),
        None,
        "a code two steps stale must not be accepted"
    );
    assert_eq!(
        super::matching_step(&secret, &code, now - 2 * ms_per_step).unwrap(),
        None,
        "a code two steps early must not be accepted"
    );
}

/// The step is what the replay guard stores, so it must advance with the clock
/// and be stable within one window.
#[test]
fn the_step_advances_once_per_window() {
    let ms_per_step = STEP_SECONDS as i64 * 1000;
    let base = 1_700_000_000_000_i64;
    let start = super::step_at(base - base % ms_per_step);
    assert_eq!(super::step_at(base - base % ms_per_step + 1), start);
    assert_eq!(
        super::step_at(base - base % ms_per_step + ms_per_step),
        start + 1
    );
}

#[test]
fn a_generated_secret_is_base32_and_long_enough() {
    let secret = super::generate_secret();
    assert!(
        secret
            .chars()
            .all(|c| c.is_ascii_uppercase() || ('2'..='7').contains(&c)),
        "{secret} is not RFC 4648 base32"
    );
    // 20 bytes at 5 bits a character.
    assert_eq!(secret.len(), 32);
    assert_ne!(secret, super::generate_secret(), "secrets must not repeat");
}

#[test]
fn the_provisioning_uri_names_the_issuer_and_account() {
    let secret = super::generate_secret();
    let uri = super::provisioning_uri(&secret, "slim-m demo", "ada").unwrap();
    assert!(uri.starts_with("otpauth://totp/"), "{uri}");
    assert!(uri.contains(&format!("secret={secret}")), "{uri}");
    assert!(uri.contains("issuer=slim-m%20demo"), "{uri}");
    assert!(uri.contains("ada"), "{uri}");
}

#[test]
fn an_issuer_with_a_colon_still_builds_a_uri() {
    let uri = super::provisioning_uri(&super::generate_secret(), "Gaming: Wednesdays", "ada")
        .expect("a Space name with a colon is a valid name");
    assert!(uri.contains("issuer=Gaming%20%20Wednesdays"), "{uri}");
}

/// The URI carries no `algorithm`, `digits` or `period`, and that is the point
/// rather than an omission: those three are exactly the otpauth defaults, and
/// several authenticator apps mis-handle them when they are stated explicitly.
/// If the parameters in `super` ever stop being the defaults, this fails and
/// says the URI has to start naming them.
#[test]
fn the_uri_leaves_the_default_parameters_implicit() {
    let uri = super::provisioning_uri(&super::generate_secret(), "slim-m", "ada").unwrap();
    for named in ["algorithm=", "digits=", "period="] {
        assert!(!uri.contains(named), "{uri} states {named} explicitly");
    }
    assert_eq!(DIGITS, 6);
    assert_eq!(STEP_SECONDS, 30);
}

/// A stored secret that is not base32 is an error, not a silent non-match: a
/// corrupt row should surface rather than quietly locking somebody out of an
/// account whose factor looks enabled.
#[test]
fn a_corrupt_secret_is_an_error() {
    assert!(super::matching_step("not base32!", "287082", 59_000).is_err());
}

fn code_for(secret: &str, step: i64) -> String {
    let totp = super::build(secret, VERIFY_ISSUER, VERIFY_ACCOUNT).unwrap();
    totp.generate((step * STEP_SECONDS as i64) as u64)
}

/// A recovery code is read off a screen and typed somewhere else, so its shape
/// is a usability property as much as a security one. The first version reused
/// the 43-character base64 secret and produced a block nobody could transcribe.
#[test]
fn a_recovery_code_is_grouped_and_transcribable() {
    let code = super::generate_recovery_code();
    assert_eq!(
        code.len(),
        23,
        "{code} is not four groups of five plus dashes"
    );
    let groups: Vec<&str> = code.split('-').collect();
    assert_eq!(groups.len(), 4);
    for group in &groups {
        assert_eq!(group.len(), 5, "{code} has an uneven group");
        assert!(
            group
                .chars()
                .all(|c| c.is_ascii_uppercase() || ('2'..='7').contains(&c)),
            "{code} is not RFC 4648 base32"
        );
    }
    assert_ne!(
        code,
        super::generate_recovery_code(),
        "codes must not repeat"
    );
}

/// Somebody retyping a grouped code gets the dashes wrong or pastes it in lower
/// case, and neither should read as a wrong code.
#[test]
fn normalizing_a_recovery_code_forgives_dashes_and_case() {
    let code = super::generate_recovery_code();
    let canonical = super::normalize_recovery_code(&code);
    assert_eq!(canonical.len(), 20);
    assert!(!canonical.contains('-'));
    for typed in [
        code.to_ascii_lowercase(),
        code.replace('-', ""),
        format!("  {}  ", code.replace('-', " ")),
    ] {
        assert_eq!(
            super::normalize_recovery_code(&typed),
            canonical,
            "{typed:?} should normalize to the stored form"
        );
    }
}

/// Every character has to be reachable, or the alphabet is smaller than the
/// entropy claim in this module's own doc.
#[test]
fn the_recovery_alphabet_is_fully_covered() {
    let mut seen = std::collections::HashSet::new();
    for _ in 0..500 {
        seen.extend(super::normalize_recovery_code(&super::generate_recovery_code()).chars());
    }
    assert_eq!(
        seen.len(),
        super::RECOVERY_ALPHABET.len(),
        "some characters are never drawn: {seen:?}"
    );
}

#[test]
fn successive_locks_lengthen_up_to_a_day() {
    let waits: Vec<i64> = (1..=6)
        .map(|run| super::lockout_ms(run * MAX_FAILURES))
        .collect();
    assert_eq!(waits[0], 15 * 60_000);
    assert!(waits.windows(2).all(|pair| pair[1] >= pair[0]), "{waits:?}");
    assert_eq!(waits[3], 24 * 60 * 60_000);
    assert_eq!(waits[5], waits[3], "the ladder ends at a day");
}
