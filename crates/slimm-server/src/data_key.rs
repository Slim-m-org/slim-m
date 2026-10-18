// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The key that seals secrets the server must read back, kept out of the database.
//!
//! A TOTP secret cannot be hashed, so it is encrypted instead; with the key beside it in the
//! database that would buy nothing. The key comes from `SLIMM_DATA_KEY`, or from a file next to
//! the database that is created on first start with mode 0600. A copy of the database alone, a
//! Litestream replica included, therefore cannot read the secrets.

use std::path::{Path, PathBuf};

use anyhow::{Context, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use crypto_secretbox::aead::rand_core::{OsRng, TryRngCore};
use crypto_secretbox::aead::{Aead, KeyInit};
use crypto_secretbox::{Key, Nonce, XSalsa20Poly1305};

const KEY_BYTES: usize = 32;
const NONCE_BYTES: usize = 24;
const SEALED_PREFIX: &str = "enc1:";
/// The file name next to the database; backups must carry it, see docs/OPERATING.md.
pub const KEY_FILE_NAME: &str = "slimm-data.key";

/// A 32-byte symmetric key. Not `Debug`, so it cannot reach a log.
#[derive(Clone)]
pub struct DataKey {
    cipher: XSalsa20Poly1305,
}

impl DataKey {
    pub fn from_bytes(bytes: [u8; KEY_BYTES]) -> Self {
        Self {
            cipher: XSalsa20Poly1305::new(&Key::from(bytes)),
        }
    }

    /// A key that lives only in this process: for tests and for tools that never touch a secret.
    pub fn ephemeral() -> Self {
        Self::from_bytes(random_bytes())
    }

    /// `SLIMM_DATA_KEY` (base64 of 32 bytes) when set, else the key file beside the database,
    /// created if this is the first start.
    pub fn load(env_key: Option<&str>, database_path: &str) -> anyhow::Result<Self> {
        if let Some(raw) = env_key.map(str::trim).filter(|raw| !raw.is_empty()) {
            return parse_key(raw).context("SLIMM_DATA_KEY");
        }
        let path = key_file_path(database_path);
        match std::fs::read_to_string(&path) {
            Ok(text) => parse_key(text.trim()).with_context(|| path.display().to_string()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => create_key_file(&path),
            Err(err) => Err(err).with_context(|| path.display().to_string()),
        }
    }

    /// As [`Self::load`], but refuses to invent a key when `sealed_rows_exist` and none was
    /// supplied: a fresh key would silently lock out every member with two-factor on.
    /// `allow_new` is the operator's explicit opt-out, for after the factors were cleared.
    pub fn load_guarded(
        env_key: Option<&str>,
        database_path: &str,
        sealed_rows_exist: bool,
        allow_new: bool,
    ) -> anyhow::Result<Self> {
        let has_env = env_key.is_some_and(|raw| !raw.trim().is_empty());
        let path = key_file_path(database_path);
        if sealed_rows_exist && !allow_new && !has_env && !path.exists() {
            bail!(
                "two-factor secrets are sealed in the database but neither SLIMM_DATA_KEY nor {} \
                 exists; restore the key that was backed up with this database. If it is gone, \
                 clear every factor with `slimm-server clear-totp <username>` and start once with \
                 SLIMM_DATA_KEY_ALLOW_NEW=1",
                path.display()
            );
        }
        Self::load(env_key, database_path)
    }

    /// Seals `plaintext` for the row `context` names; opening it for any other row fails.
    pub fn seal(&self, context: &str, plaintext: &str) -> anyhow::Result<String> {
        let nonce_bytes: [u8; NONCE_BYTES] = random_bytes();
        let bound = format!("{context}\n{plaintext}");
        let ciphertext = self
            .cipher
            .encrypt(&Nonce::from(nonce_bytes), bound.as_bytes())
            .map_err(|_| anyhow::anyhow!("sealing failed"))?;
        let mut blob = nonce_bytes.to_vec();
        blob.extend_from_slice(&ciphertext);
        Ok(format!("{SEALED_PREFIX}{}", BASE64.encode(blob)))
    }

    /// The plaintext of a [`Self::seal`] output for the same `context`. A value that was never
    /// sealed is returned as is: it predates sealing and the startup pass has yet to reach it.
    pub fn open(&self, context: &str, stored: &str) -> anyhow::Result<String> {
        let Some(encoded) = stored.strip_prefix(SEALED_PREFIX) else {
            return Ok(stored.to_owned());
        };
        let blob = BASE64
            .decode(encoded)
            .context("sealed value is not base64")?;
        if blob.len() <= NONCE_BYTES {
            bail!("sealed value is truncated");
        }
        let (nonce, ciphertext) = blob.split_at(NONCE_BYTES);
        let nonce: [u8; NONCE_BYTES] = nonce.try_into().expect("split at the nonce length");
        let bound = self
            .cipher
            .decrypt(&Nonce::from(nonce), ciphertext)
            .map_err(|_| anyhow::anyhow!("the data key does not open this value"))?;
        let bound = String::from_utf8(bound).context("sealed value is not text")?;
        match bound.split_once('\n') {
            Some((bound_to, plaintext)) if bound_to == context => Ok(plaintext.to_owned()),
            _ => bail!("sealed value belongs to another row"),
        }
    }

    pub fn is_sealed(stored: &str) -> bool {
        stored.starts_with(SEALED_PREFIX)
    }
}

fn random_bytes<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    OsRng
        .try_fill_bytes(&mut bytes)
        .expect("the operating system has entropy");
    bytes
}

fn key_file_path(database_path: &str) -> PathBuf {
    Path::new(database_path)
        .parent()
        .filter(|dir| !dir.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
        .join(KEY_FILE_NAME)
}

fn parse_key(text: &str) -> anyhow::Result<DataKey> {
    let bytes = BASE64.decode(text).context("not base64")?;
    let bytes: [u8; KEY_BYTES] = bytes
        .try_into()
        .map_err(|_| anyhow::anyhow!("must be exactly {KEY_BYTES} bytes"))?;
    Ok(DataKey::from_bytes(bytes))
}

/// Creates the key file exclusively, so two processes starting together agree on one key.
fn create_key_file(path: &Path) -> anyhow::Result<DataKey> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    let bytes: [u8; KEY_BYTES] = random_bytes();
    let created = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path);
    match created {
        Ok(mut file) => {
            writeln!(file, "{}", BASE64.encode(bytes))
                .and_then(|()| file.sync_all())
                .with_context(|| path.display().to_string())?;
            tracing::info!(path = %path.display(), "created the data key file; back it up with the database");
            Ok(DataKey::from_bytes(bytes))
        }
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
            let text = std::fs::read_to_string(path).with_context(|| path.display().to_string())?;
            parse_key(text.trim()).with_context(|| path.display().to_string())
        }
        Err(err) => Err(err).with_context(|| path.display().to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sealed_value_opens_only_for_its_own_row() {
        let key = DataKey::ephemeral();
        let sealed = key.seal("user-a", "JBSWY3DPEHPK3PXP").unwrap();
        assert!(DataKey::is_sealed(&sealed));
        assert!(!sealed.contains("JBSWY3DPEHPK3PXP"));
        assert_eq!(key.open("user-a", &sealed).unwrap(), "JBSWY3DPEHPK3PXP");
        assert!(key.open("user-b", &sealed).is_err());
    }

    #[test]
    fn another_key_cannot_open_it() {
        let sealed = DataKey::ephemeral().seal("u", "secret").unwrap();
        assert!(DataKey::ephemeral().open("u", &sealed).is_err());
    }

    #[test]
    fn an_unsealed_legacy_value_passes_through() {
        assert_eq!(
            DataKey::ephemeral().open("u", "JBSWY3DPEHPK3PXP").unwrap(),
            "JBSWY3DPEHPK3PXP"
        );
    }

    #[test]
    fn a_tampered_value_is_refused() {
        let key = DataKey::ephemeral();
        let sealed = key.seal("u", "secret").unwrap();
        let mut blob = BASE64
            .decode(sealed.strip_prefix(SEALED_PREFIX).unwrap())
            .unwrap();
        *blob.last_mut().unwrap() ^= 1;
        let tampered = format!("{SEALED_PREFIX}{}", BASE64.encode(blob));
        assert!(key.open("u", &tampered).is_err());
    }

    #[test]
    fn the_key_file_is_created_private_and_reused() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("slimm-data-key-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("slimm.db");
        let db = db.to_str().unwrap();

        let first = DataKey::load(None, db).unwrap();
        let file = dir.join(KEY_FILE_NAME);
        let mode = std::fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        let sealed = first.seal("u", "secret").unwrap();
        let second = DataKey::load(None, db).unwrap();
        assert_eq!(second.open("u", &sealed).unwrap(), "secret");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_environment_key_wins_over_the_file() {
        let env = BASE64.encode([7u8; KEY_BYTES]);
        let a = DataKey::load(Some(&env), "/nonexistent/dir/slimm.db").unwrap();
        let b = DataKey::load(Some(&env), "/other/slimm.db").unwrap();
        let sealed = a.seal("u", "secret").unwrap();
        assert_eq!(b.open("u", &sealed).unwrap(), "secret");
    }

    #[test]
    fn a_missing_key_with_sealed_rows_refuses_to_start_unless_opted_out() {
        let dir = std::env::temp_dir().join(format!("slimm-data-key-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("slimm.db");
        let db = db.to_str().unwrap();

        let refused = DataKey::load_guarded(None, db, true, false).err().unwrap();
        assert!(refused.to_string().contains("SLIMM_DATA_KEY"), "{refused}");
        assert!(!dir.join(KEY_FILE_NAME).exists(), "no key was invented");

        DataKey::load_guarded(None, db, false, false).unwrap();
        assert!(
            DataKey::load_guarded(None, db, true, false).is_ok(),
            "the file exists now"
        );
        std::fs::remove_dir_all(&dir).unwrap();

        let env = BASE64.encode([7u8; KEY_BYTES]);
        assert!(DataKey::load_guarded(Some(&env), "/nonexistent/x.db", true, false).is_ok());
    }

    #[test]
    fn the_opt_out_creates_a_fresh_key() {
        let dir = std::env::temp_dir().join(format!("slimm-data-key-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("slimm.db");
        DataKey::load_guarded(None, db.to_str().unwrap(), true, true).unwrap();
        assert!(dir.join(KEY_FILE_NAME).exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_malformed_environment_key_is_an_error() {
        assert!(DataKey::load(Some("not-a-key"), "x/slimm.db").is_err());
        assert!(DataKey::load(Some(&BASE64.encode([1u8; 16])), "x/slimm.db").is_err());
    }
}
