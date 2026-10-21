// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The authentication service: password hashing and opaque-token primitives.
//!
//! Two concerns live here, kept apart from persistence on purpose:
//!
//! - Password hashing with Argon2id. It is memory-hard (~19 MiB per hash) and
//!   CPU-bound, so every hash runs on a blocking thread and a [`Semaphore`]
//!   caps how many run at once. That bound is what keeps a burst of logins from
//!   claiming `19 MiB * requests` all at the same time. Waiting for a permit is
//!   itself bounded: past a deadline the request is shed as [`HashError::Busy`]
//!   rather than queuing without limit. This is a backstop, not a substitute for
//!   the per-caller rate limiting still owed at the edge.
//! - Opaque token secrets. A token is high-entropy random bytes handed to the
//!   client once; the server stores only its SHA-256 so a database leak never
//!   yields a usable credential. [`generate_secret`] mints one, [`hash_secret`]
//!   turns a presented secret back into the stored lookup key.
//!
//! Argon2id parameters follow the OWASP baseline: 19 MiB, 2 iterations, 1 lane.

use std::sync::Arc;
use std::time::Duration;

use anyhow::anyhow;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

/// OWASP Argon2id baseline: 19 MiB of memory, 2 passes, 1 degree of parallelism.
const ARGON_MEMORY_KIB: u32 = 19 * 1024;
const ARGON_ITERATIONS: u32 = 2;
const ARGON_LANES: u32 = 1;

/// How long a request will wait for a hashing permit before it is shed. Bounds
/// the queue so a hashing backlog fails fast instead of piling up unboundedly.
const HASH_ACQUIRE_TIMEOUT: Duration = Duration::from_secs(3);

/// Why a password hash or verify could not complete.
#[derive(Debug)]
pub enum HashError {
    /// No hashing permit became free within the deadline; shed the request.
    Busy,
    /// An unexpected internal failure (RNG, a panicked task, a bad parameter).
    Internal(anyhow::Error),
}

/// Password hashing and verification, with a bound on concurrent hashes.
#[derive(Clone)]
pub struct Auth {
    argon: Argon2<'static>,
    permits: Arc<Semaphore>,
    acquire_timeout: Duration,
    /// A precomputed valid hash. Verifying a login for a username that does not
    /// exist runs against this so the response time does not reveal whether the
    /// account is real.
    dummy_hash: Arc<str>,
}

impl Auth {
    /// Builds the service, precomputing the decoy hash once at startup.
    /// `concurrency` is clamped to at least one.
    pub fn new(concurrency: usize) -> anyhow::Result<Self> {
        let params = Params::new(ARGON_MEMORY_KIB, ARGON_ITERATIONS, ARGON_LANES, None)
            .map_err(|e| anyhow!("invalid Argon2 parameters: {e}"))?;
        let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

        let salt = SaltString::generate(&mut OsRng);
        let dummy_hash: Arc<str> = argon
            .hash_password(b"slim-m-decoy-password", &salt)
            .map_err(|e| anyhow!("precomputing decoy hash: {e}"))?
            .to_string()
            .into();

        Ok(Self {
            argon,
            permits: Arc::new(Semaphore::new(concurrency.max(1))),
            acquire_timeout: HASH_ACQUIRE_TIMEOUT,
            dummy_hash,
        })
    }

    #[cfg(test)]
    fn with_acquire_timeout(mut self, timeout: Duration) -> Self {
        self.acquire_timeout = timeout;
        self
    }

    /// Acquires a hashing permit or sheds the request past the deadline.
    async fn acquire(&self) -> Result<OwnedSemaphorePermit, HashError> {
        match tokio::time::timeout(self.acquire_timeout, self.permits.clone().acquire_owned()).await
        {
            Ok(Ok(permit)) => Ok(permit),
            Ok(Err(_closed)) => Err(HashError::Internal(anyhow!("hashing semaphore closed"))),
            Err(_elapsed) => Err(HashError::Busy),
        }
    }

    /// Hashes a password into a PHC string for storage. The permit moves into
    /// the blocking hash, so the memory bound holds even when the request that
    /// started it is cancelled: a blocking task cannot be stopped mid-hash.
    pub async fn hash_password(&self, password: String) -> Result<String, HashError> {
        let permit = self.acquire().await?;
        let argon = self.argon.clone();
        let joined = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let salt = SaltString::generate(&mut OsRng);
            argon
                .hash_password(password.as_bytes(), &salt)
                .map(|hash| hash.to_string())
                .map_err(|e| anyhow!("hashing password: {e}"))
        })
        .await
        .map_err(|e| HashError::Internal(anyhow!("password hash task panicked: {e}")))?;
        joined.map_err(HashError::Internal)
    }

    /// Verifies a password against a stored PHC hash. A malformed stored hash
    /// verifies as a non-match rather than an error, so one corrupt row cannot
    /// lock an account into 500s.
    pub async fn verify_password(&self, password: String, phc: String) -> Result<bool, HashError> {
        let permit = self.acquire().await?;
        let argon = self.argon.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            match PasswordHash::new(&phc) {
                Ok(parsed) => argon.verify_password(password.as_bytes(), &parsed).is_ok(),
                Err(_) => false,
            }
        })
        .await
        .map_err(|e| HashError::Internal(anyhow!("password verify task panicked: {e}")))
    }

    /// Burns roughly one verification's worth of time against the decoy hash.
    /// Called on the no-such-user path so timing does not leak account existence.
    ///
    /// Propagates [`HashError`] rather than swallowing it: under semaphore
    /// contention the real-user branch answers 503, and if this branch
    /// answered an instant 401 instead, the load itself would become the
    /// oracle this decoy exists to close.
    pub async fn verify_decoy(&self) -> Result<(), HashError> {
        self.verify_password(
            "slim-m-decoy-password".to_owned(),
            self.dummy_hash.to_string(),
        )
        .await
        .map(|_| ())
    }
}

/// Mints a fresh opaque token secret: 256 bits of OS randomness, URL-safe base64.
/// This is the value handed to the client; only its [`hash_secret`] is stored.
pub(crate) fn generate_secret() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

/// The lookup key for a token secret: lowercase-hex SHA-256. Deterministic, so a
/// presented secret hashes to the same key that was stored at issue time.
pub(crate) fn hash_secret(secret: &str) -> String {
    let digest = Sha256::digest(secret.as_bytes());
    let mut hex = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(hex, "{byte:02x}");
    }
    hex
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::{Auth, HashError, hash_secret};

    fn one_permit() -> Auth {
        Auth::new(1)
            .unwrap()
            .with_acquire_timeout(Duration::from_millis(30))
    }

    async fn hold_the_permit(auth: &Auth) -> tokio::task::JoinHandle<()> {
        let holder = auth.clone();
        let task = tokio::spawn(async move {
            let _ = holder.hash_password("x".repeat(64)).await;
        });
        let started = Instant::now();
        while auth.permits.available_permits() > 0 {
            assert!(
                started.elapsed() < Duration::from_secs(5),
                "hash never started"
            );
            tokio::task::yield_now().await;
        }
        task
    }

    #[tokio::test]
    async fn a_saturated_hasher_sheds_real_and_decoy_logins_alike() {
        let auth = one_permit();
        let _held = hold_the_permit(&auth).await;

        let real = auth
            .verify_password("pw".to_owned(), "not-a-phc".to_owned())
            .await;
        let decoy = auth.verify_decoy().await;
        assert!(matches!(real, Err(HashError::Busy)), "{real:?}");
        assert!(matches!(decoy, Err(HashError::Busy)), "{decoy:?}");
    }

    #[tokio::test]
    async fn a_cancelled_request_keeps_its_permit_until_the_hash_ends() {
        let auth = one_permit();
        let held = hold_the_permit(&auth).await;
        held.abort();
        let _ = held.await;

        // Checked at once, not by racing a second hash: a fast runner finishes a real hash inside any wait.
        assert_eq!(
            auth.permits.available_permits(),
            0,
            "a cancelled login freed its permit while its hash kept running"
        );
        let started = Instant::now();
        while auth.permits.available_permits() == 0 {
            assert!(
                started.elapsed() < Duration::from_secs(10),
                "the permit never came back after the hash ended"
            );
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }

    /// Pinned against the published SHA-256 vectors, lowercase hex: the stored
    /// hash of an invite or reset code is looked up by exact string, so the
    /// algorithm and the encoding can never drift without every existing code
    /// silently ceasing to match.
    #[test]
    fn hash_secret_is_lowercase_hex_sha256() {
        assert_eq!(
            hash_secret(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hash_secret("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn hash_secret_is_deterministic_and_separates_inputs() {
        assert_eq!(hash_secret("code-1"), hash_secret("code-1"));
        assert_ne!(hash_secret("code-1"), hash_secret("code-2"));
    }
}
