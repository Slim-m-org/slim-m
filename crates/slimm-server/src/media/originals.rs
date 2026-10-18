// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The files and limits around photo compression: the original kept beside a
//! compressed attachment, and the budget that bounds concurrent compressions.

use std::io;
use std::path::PathBuf;

use tokio::sync::{Semaphore, SemaphorePermit};

use super::Media;

/// Appended to an attachment's name for the original kept beside it.
pub const ORIGINAL_SUFFIX: &str = ".orig";

/// Work units of photo compression that may run at once. A job asks for one unit
/// per 24 megapixels, up to the whole budget, so memory stays bounded however
/// many uploads arrive together.
const COMPRESSION_BUDGET: u32 = 4;

/// Process-wide: the work is bounded by the machine, not by one `Media` handle.
static COMPRESSION: Semaphore = Semaphore::const_new(COMPRESSION_BUDGET as usize);

impl Media {
    /// Where the original upload kept beside attachment `sha256_hex` lives.
    pub fn original_path(&self, sha256_hex: &str) -> PathBuf {
        self.attachments_dir
            .join(format!("{sha256_hex}{ORIGINAL_SUFFIX}"))
    }

    /// Waits for room to decode a picture of `pixels` and holds it until dropped.
    pub async fn compression_slot(&self, pixels: u64) -> SemaphorePermit<'static> {
        let units = pixels
            .div_ceil(24_000_000)
            .clamp(1, u64::from(COMPRESSION_BUDGET)) as u32;
        COMPRESSION
            .acquire_many(units)
            .await
            .expect("the compression semaphore is never closed")
    }

    /// Opens the kept original of an attachment for streaming.
    pub async fn open_original(&self, sha256_hex: &str) -> io::Result<(tokio::fs::File, u64)> {
        let file = tokio::fs::File::open(self.original_path(sha256_hex)).await?;
        let len = file.metadata().await?.len();
        Ok((file, len))
    }
}
