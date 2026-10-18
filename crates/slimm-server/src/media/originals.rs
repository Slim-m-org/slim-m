// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The files and limits around photo compression: the original kept beside a
//! compressed attachment, and the budget that bounds concurrent compressions.

use std::io;
use std::path::PathBuf;

use tokio::sync::OwnedSemaphorePermit;

use super::Media;
use super::memory_budget::MemoryBudget;

/// Appended to an attachment's name for the original kept beside it.
pub const ORIGINAL_SUFFIX: &str = ".orig";

impl Media {
    /// Where the original upload kept beside attachment `sha256_hex` lives.
    pub fn original_path(&self, sha256_hex: &str) -> PathBuf {
        self.attachments_dir
            .join(format!("{sha256_hex}{ORIGINAL_SUFFIX}"))
    }

    /// Reserves room to compress a file whose peak memory is estimated at `estimate` bytes.
    pub async fn admit_memory(&self, estimate: u64) -> Option<OwnedSemaphorePermit> {
        self.memory.admit(estimate).await
    }

    /// Replaces the compression memory budget, so a test can shrink it.
    pub fn with_memory_budget(mut self, budget: MemoryBudget) -> Self {
        self.memory = budget.clone();
        self.previews.use_budget(budget);
        self
    }

    /// Opens the kept original of an attachment for streaming.
    pub async fn open_original(&self, sha256_hex: &str) -> io::Result<(tokio::fs::File, u64)> {
        let file = tokio::fs::File::open(self.original_path(sha256_hex)).await?;
        let len = file.metadata().await?.len();
        Ok((file, len))
    }
}
