// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The server's long-lived identity: an Ed25519 keypair generated once on
//! first boot and persisted forever, so a self-hosted deployment has
//! something stable a client can pin.
//!
//! This is deliberately not derived from the TLS certificate. This product
//! supports plain-HTTP LAN deployments, which have no certificate to derive
//! anything from, and reverse proxies that terminate TLS in front of it,
//! where the certificate a client actually sees belongs to the proxy and
//! changes on every renewal even though the deployment behind it has not
//! changed at all. An identity that lived in the certificate would therefore
//! be either absent or spuriously unstable for exactly the deployments this
//! product targets.
//!
//! What trust-on-first-use protects here, stated precisely so it is not
//! oversold: **nothing about the first connection**. A machine-in-the-middle
//! present from the very first request can generate its own keypair and hand
//! out its own fingerprint, and a client with nothing pinned yet has no way
//! to tell the difference. What it protects is **every connection after the
//! first**: once a client has pinned this key, an attacker who was not
//! already positioned at that moment cannot substitute themselves later
//! without the fingerprint visibly changing. That is a real property against
//! a network that turns hostile later, a DNS or routing change that lands on
//! the wrong host, or a typo'd address that happens to reach someone else's
//! server. It does not stop a relay that forwards `/version` to the real
//! server: that response is public and nothing here signs anything, so the
//! real key reaches the client unchanged. It is not a substitute for checking the fingerprint out of band
//! (the admin reading it aloud) on that first connection, which is why the
//! onboarding design surfaces it as something to compare rather than
//! something to trust silently.

use anyhow::Context;
use ed25519_dalek::SigningKey;
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256};
use sqlx::SqlitePool;

/// Ed25519 public keys are exactly 32 bytes.
const PUBLIC_KEY_BYTES: usize = 32;

/// How many bytes of the SHA-256 digest become the displayed fingerprint.
/// Eight 4-character hex groups (the onboarding design's two rows of four)
/// need 32 hex characters, so 16 bytes. Truncating a cryptographic hash to
/// 128 bits does not weaken what a human comparison protects: producing a
/// different key whose hash collides in the kept 128 bits is a full
/// preimage search against SHA-256, not meaningfully easier than attacking
/// the 256-bit Ed25519 key directly.
const FINGERPRINT_BYTES: usize = 16;

/// How many colours the client's cursor palette has (`AppCanvasColors.cursors`
/// on the client side). Kept here as the one place the server needs to agree
/// with the client on this number.
const PALETTE_COLORS: u8 = 6;

/// How many entries the colour strip shows.
const COLOR_STRIP_LEN: usize = 4;

/// The server's identity: the public half of the keypair, and everything
/// derived from it that a client displays or pins.
///
/// Deliberately does not carry the secret key: nothing here signs anything
/// yet, so there is nothing in memory for a signing operation to use, and
/// the persisted secret is read back only to re-derive this same public key
/// on the next boot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ServerIdentity {
    public_key: [u8; PUBLIC_KEY_BYTES],
}

impl ServerIdentity {
    /// The raw public key. This, not the truncated fingerprint below, is
    /// what a client should store and compare byte-for-byte on every later
    /// connect: the fingerprint is a human-legible view of it, not a
    /// separate credential.
    pub fn public_key(&self) -> [u8; PUBLIC_KEY_BYTES] {
        self.public_key
    }

    /// A deterministic 128-bit fingerprint of the public key.
    fn fingerprint(&self) -> [u8; FINGERPRINT_BYTES] {
        let digest = Sha256::digest(self.public_key);
        let mut out = [0u8; FINGERPRINT_BYTES];
        out.copy_from_slice(&digest[..FINGERPRINT_BYTES]);
        out
    }

    /// The fingerprint as one lowercase hex string with no separators, for a
    /// client to store or compare programmatically.
    pub fn fingerprint_hex(&self) -> String {
        hex_lower(&self.fingerprint())
    }

    /// The same fingerprint, split into eight 4-character hex groups, for
    /// display. The onboarding design wraps these as two rows of four; how
    /// to lay them out is a client-side decision, not this server's.
    pub fn fingerprint_groups(&self) -> Vec<String> {
        let hex = self.fingerprint_hex();
        hex.as_bytes()
            .chunks(4)
            .map(|chunk| {
                std::str::from_utf8(chunk)
                    .expect("hex digits are ASCII")
                    .to_owned()
            })
            .collect()
    }

    /// Four indices into a six-colour palette, deterministically derived
    /// from the fingerprint, for an at-a-glance colour strip alongside the
    /// hex a person is asked to read aloud.
    pub fn color_strip(&self) -> [u8; COLOR_STRIP_LEN] {
        let fp = self.fingerprint();
        let mut strip = [0u8; COLOR_STRIP_LEN];
        for (slot, byte) in strip.iter_mut().zip(fp.iter()) {
            *slot = byte % PALETTE_COLORS;
        }
        strip
    }
}

fn hex_lower(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(out, "{byte:02x}").expect("writing hex digits into a String never fails");
    }
    out
}

/// Loads the persisted identity keypair, generating and storing one if this
/// is the first boot.
///
/// The secret is 32 bytes of OS randomness; the public key is derived from
/// it by the standard Ed25519 key schedule rather than stored independently,
/// so the two halves can never disagree. Both persist in `server_identity`,
/// so the fingerprint a client has pinned survives every restart.
///
/// If another process (or another connection racing startup) inserts first,
/// the row that actually landed is read back rather than the key generated in
/// this call, so every caller ends up agreeing on the same identity.
pub async fn load_or_create(pool: &SqlitePool) -> anyhow::Result<ServerIdentity> {
    if let Some(identity) = read(pool).await? {
        return Ok(identity);
    }

    let mut seed = [0u8; 32];
    OsRng.fill_bytes(&mut seed);
    let public_key = SigningKey::from_bytes(&seed).verifying_key().to_bytes();
    let seed_ref = seed.as_slice();
    let public_ref = public_key.as_slice();
    let now = crate::store::now_ms();

    let claim = sqlx::query!(
        "INSERT INTO server_identity (id, secret_key, public_key, created_at)
         VALUES (1, ?, ?, ?)",
        seed_ref,
        public_ref,
        now
    )
    .execute(pool)
    .await;

    match claim {
        Ok(_) => Ok(ServerIdentity { public_key }),
        // Lost the insert race, so read back the winner; see the note on
        // this function.
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => read(pool)
            .await?
            .context("server_identity insert lost a race but no row is readable"),
        Err(e) => Err(e.into()),
    }
}

/// A 32-byte key derived from the identity secret for one named purpose.
///
/// Derived rather than the seed itself, so the signing key is never also a
/// MAC key and two purposes never share one. It never leaves the server.
pub async fn derived_key(pool: &SqlitePool, purpose: &[u8]) -> anyhow::Result<[u8; 32]> {
    use hmac::{Hmac, Mac};

    load_or_create(pool).await?;
    let seed: Vec<u8> = sqlx::query_scalar("SELECT secret_key FROM server_identity WHERE id = 1")
        .fetch_one(pool)
        .await?;
    let mut mac = <Hmac<Sha256>>::new_from_slice(&seed).context("keying the derivation")?;
    mac.update(purpose);
    Ok(mac.finalize().into_bytes().into())
}

async fn read(pool: &SqlitePool) -> anyhow::Result<Option<ServerIdentity>> {
    let row =
        sqlx::query!(r#"SELECT public_key AS "public_key!" FROM server_identity WHERE id = 1"#)
            .fetch_optional(pool)
            .await?;
    let Some(row) = row else {
        return Ok(None);
    };
    let public_key: [u8; PUBLIC_KEY_BYTES] = row
        .public_key
        .try_into()
        .map_err(|_| anyhow::anyhow!("stored server identity public key is not 32 bytes"))?;
    Ok(Some(ServerIdentity { public_key }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(byte: u8) -> ServerIdentity {
        ServerIdentity {
            public_key: [byte; PUBLIC_KEY_BYTES],
        }
    }

    #[test]
    fn the_fingerprint_is_deterministic_and_key_dependent() {
        let a = identity(1);
        let b = identity(1);
        let c = identity(2);
        assert_eq!(a.fingerprint_hex(), b.fingerprint_hex());
        assert_ne!(a.fingerprint_hex(), c.fingerprint_hex());
    }

    #[test]
    fn the_fingerprint_renders_as_eight_four_character_groups() {
        let groups = identity(7).fingerprint_groups();
        assert_eq!(groups.len(), 8, "two rows of four in the onboarding design");
        for group in &groups {
            assert_eq!(group.len(), 4);
            assert!(group.chars().all(|c| c.is_ascii_hexdigit()));
        }
        assert_eq!(groups.join(""), identity(7).fingerprint_hex());
    }

    /// The inequality at the end is not a mathematical certainty for one
    /// arbitrary pair of keys, but it holds for this pair, and it is worth
    /// catching if a future edit makes the strip ignore the key entirely.
    #[test]
    fn the_color_strip_is_deterministic_and_derived_from_the_fingerprint() {
        let a = identity(9).color_strip();
        let b = identity(9).color_strip();
        assert_eq!(a, b);

        // Every index is a valid slot in the six-colour palette.
        for index in a {
            assert!(index < PALETTE_COLORS);
        }

        // A different key gives a different strip; see the note on this test.
        assert_ne!(a, identity(200).color_strip());
    }
}
