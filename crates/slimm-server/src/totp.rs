// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The TOTP primitive: mint a secret, describe it to an authenticator app, and
//! check a presented code against a counter step.
//!
//! The RFC 6238 arithmetic itself is `totp-rs`, deliberately not hand-rolled;
//! what lives here is the parameter choice, the step arithmetic the replay
//! guard in [`crate::store`] keys on, and the provisioning URI.
//!
//! Parameters are the interoperable ones every authenticator app already
//! speaks: HMAC-SHA1, six digits, a thirty-second step. SHA-256 and eight
//! digits are both in the spec and both silently produce wrong codes in
//! several popular apps, and there is nothing to gain: the secret is 160 bits
//! either way, and an attacker guessing a six-digit code is bounded by
//! [`MAX_FAILURES`] attempts, not by the digest.

use anyhow::anyhow;
use rand_core::{OsRng, RngCore};
use totp_rs::{Algorithm, Secret, TOTP};

/// Seconds per counter step. Thirty is the near-universal default; an
/// authenticator app that is told otherwise by the URI often ignores it.
pub const STEP_SECONDS: u64 = 30;

/// Digits in a code.
const DIGITS: usize = 6;

/// How many steps either side of the current one are accepted.
///
/// One, so a code is live for at most ninety seconds. Phones drift, and a
/// person reads a code near the end of its window and then types it, so zero
/// would reject honest codes routinely. Two or more starts to matter: each
/// extra step multiplies what a single guess is worth, and the replay guard
/// only stops a code being spent twice, not a wider window existing.
const SKEW_STEPS: u64 = 1;

/// Recommended secret size for HMAC-SHA1 (RFC 4226 section 4): 160 bits, the
/// digest's own block-relevant length, so nothing is gained by going shorter
/// and no key stretching happens by going longer.
const SECRET_BYTES: usize = 20;

/// How many consecutive failures lock the factor.
pub const MAX_FAILURES: i64 = 5;

/// Characters a recovery code is drawn from: RFC 4648 base32, which is
/// case-insensitive, unambiguous when read aloud, and has no `+` or `/` to be
/// mangled by a copy out of a chat message.
const RECOVERY_ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// Characters per group, and groups per code: 20 characters at five bits each,
/// so just under 100 bits.
///
/// Sized for a person, which is the whole point of a recovery code. The first
/// version reused the 43-character base64 secret every other bearer token here
/// uses, and a set of ten of those wrapped into an unreadable block nobody
/// could transcribe or tell apart - found by looking at the screen. Grouping
/// is what makes it copyable by hand.
///
/// Still far beyond guessing: the lockout bounds online attempts to five, and
/// 100 bits bounds the offline case a database leak would open, which matters
/// because these are stored as SHA-256 rather than Argon2 (they are
/// high-entropy by construction, so key stretching buys nothing).
const RECOVERY_GROUP: usize = 5;
const RECOVERY_GROUPS: usize = 4;

/// A fresh recovery code, grouped for transcription: `A3F7K-9MQ2X-P4RTV-8WYZ2`.
///
/// Drawn by rejection sampling so every character is equally likely; a plain
/// modulo over 256 would bias the first 32 of the alphabet's 32 values only
/// because 256 divides evenly, and relying on that is the kind of thing that
/// silently stops being true if the alphabet ever changes size.
pub fn generate_recovery_code() -> String {
    let mut out = String::with_capacity(RECOVERY_GROUPS * (RECOVERY_GROUP + 1) - 1);
    for group in 0..RECOVERY_GROUPS {
        if group > 0 {
            out.push('-');
        }
        for _ in 0..RECOVERY_GROUP {
            out.push(char::from(RECOVERY_ALPHABET[draw(RECOVERY_ALPHABET.len())]));
        }
    }
    out
}

/// A uniform index below `modulus`, by rejection sampling.
fn draw(modulus: usize) -> usize {
    let limit = (256 / modulus) * modulus;
    loop {
        let mut byte = [0u8; 1];
        OsRng.fill_bytes(&mut byte);
        let value = byte[0] as usize;
        if value < limit {
            return value % modulus;
        }
    }
}

/// The lookup form of a recovery code: upper-case, with the grouping dashes and
/// any surrounding whitespace removed.
///
/// One place rather than two, so what is stored at issue time and what is
/// looked up at spend time cannot drift. It exists because a person retyping a
/// grouped code gets the dashes wrong, pastes it lower-case, or both, and none
/// of that should read as a wrong code.
pub fn normalize_recovery_code(code: &str) -> String {
    code.chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|c| c.to_ascii_uppercase())
        .collect()
}

/// How long the factor stays locked once [`MAX_FAILURES`] is reached.
///
/// Long enough that grinding six digits is hopeless (five tries per fifteen
/// minutes against a million codes), short enough that somebody who fat-
/// fingered their own code five times is not locked out for the evening.
pub const LOCKOUT_MS: i64 = 15 * 60 * 1000;

/// A freshly minted secret, base32 as an authenticator app expects it.
///
/// Returned to the enrolling client once and stored as-is; see
/// `migrations/0092_totp_two_factor.sql` for why this one secret cannot be
/// hashed.
pub fn generate_secret() -> String {
    let mut bytes = [0u8; SECRET_BYTES];
    OsRng.fill_bytes(&mut bytes);
    Secret::Raw(bytes.to_vec())
        .to_encoded()
        .to_string()
        .trim_end_matches('=')
        .to_owned()
}

/// The counter step `at_ms` falls in. The replay guard stores the highest step
/// already spent, so this is what "already used" is measured in.
pub fn step_at(at_ms: i64) -> i64 {
    at_ms.div_euclid(STEP_SECONDS as i64 * 1000)
}

/// The `otpauth://` URI an authenticator app scans, naming `issuer` so the
/// entry is identifiable among a person's other accounts.
pub fn provisioning_uri(secret: &str, issuer: &str, account: &str) -> anyhow::Result<String> {
    Ok(build(secret, issuer, account)?.get_url())
}

/// Whether `code` is valid for `secret` at `at_ms`, and if so which step it
/// belongs to, so the caller can refuse a step it has already spent.
///
/// Returns `None` for a malformed or wrong code without distinguishing the
/// two: a caller that told them apart would leak whether a length or charset
/// guess was closer.
pub fn matching_step(secret: &str, code: &str, at_ms: i64) -> anyhow::Result<Option<i64>> {
    let totp = build(secret, VERIFY_ISSUER, VERIFY_ACCOUNT)?;
    let current = step_at(at_ms);
    let skew = SKEW_STEPS as i64;
    for step in (current - skew)..=(current + skew) {
        let seconds = u64::try_from(step.saturating_mul(STEP_SECONDS as i64))
            .map_err(|_| anyhow!("counter step before the unix epoch"))?;
        if totp.generate(seconds) == code {
            return Ok(Some(step));
        }
    }
    Ok(None)
}

/// The code `secret` produces for the step containing `at_ms`.
///
/// `pub` for the integration tests and the e2e harness, which have to act as
/// the authenticator app: there is no way to exercise a sign-in challenge, a
/// replay, or the edge of the skew window without producing a real code.
/// Discloses nothing - anybody holding the secret can compute this anyway,
/// which is what makes the secret the thing to protect.
pub fn code_at(secret: &str, at_ms: i64) -> anyhow::Result<String> {
    let seconds = u64::try_from(step_at(at_ms).saturating_mul(STEP_SECONDS as i64))
        .map_err(|_| anyhow!("counter step before the unix epoch"))?;
    Ok(build(secret, VERIFY_ISSUER, VERIFY_ACCOUNT)?.generate(seconds))
}

/// A verification never renders a URI, but `totp-rs` validates the label when
/// it builds, so these stand in rather than leaving it empty.
const VERIFY_ISSUER: &str = "slim-m";
const VERIFY_ACCOUNT: &str = "verify";

fn build(secret: &str, issuer: &str, account: &str) -> anyhow::Result<TOTP> {
    let bytes = Secret::Encoded(secret.to_owned())
        .to_bytes()
        .map_err(|_| anyhow!("stored TOTP secret is not valid base32"))?;
    TOTP::new(
        Algorithm::SHA1,
        DIGITS,
        SKEW_STEPS as u8,
        STEP_SECONDS,
        bytes,
        Some(issuer.to_owned()),
        account.to_owned(),
    )
    .map_err(|e| anyhow!("building TOTP: {e}"))
}

#[cfg(test)]
mod tests;
