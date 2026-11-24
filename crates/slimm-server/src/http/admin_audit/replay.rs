// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Tells a replayed idempotent write from a second, different change to the same target.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

const WINDOW: Duration = Duration::from_secs(30);

type Seen = HashMap<[u8; 32], Instant>;

fn seen() -> &'static Mutex<Seen> {
    static SEEN: OnceLock<Mutex<Seen>> = OnceLock::new();
    SEEN.get_or_init(Mutex::default)
}

/// The identity of one write: who, what, on which target, with which values.
pub struct Write<'a> {
    pub actor: &'a str,
    pub action: &'a str,
    pub target: Option<&'a str>,
    pub detail: &'a str,
    pub body: &'a str,
}

impl Write<'_> {
    fn key(&self) -> [u8; 32] {
        let mut hasher = Sha256::new();
        for part in [
            self.actor,
            self.action,
            self.target.unwrap_or(""),
            self.detail,
            self.body,
        ] {
            hasher.update((part.len() as u64).to_le_bytes());
            hasher.update(part.as_bytes());
        }
        hasher.finalize().into()
    }

    /// Whether this exact write, values included, was already seen inside the window; marks it seen.
    pub fn is_replay(&self) -> bool {
        let now = Instant::now();
        let mut seen = seen()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        seen.retain(|_, at| now.duration_since(*at) < WINDOW);
        seen.insert(self.key(), now).is_some()
    }

    /// Forgets the write, so a retry after a failed insert is not taken for a replay.
    pub fn forget(&self) {
        let mut seen = seen()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        seen.remove(&self.key());
    }
}
