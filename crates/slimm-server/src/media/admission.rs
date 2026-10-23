// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bytes promised to the deployment-wide ceiling but not yet in `attachments`.
//!
//! The ceiling check reads the stored total, so anything that has been agreed
//! to but not yet recorded has to be counted beside it or concurrent uploads
//! all pass the same stale number. Two kinds exist: an open resumable session
//! (it holds its declared size on disk until it completes or expires) and a
//! [`Reservation`] held across the gap between a final check and the row.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

/// Bytes held back from the ceiling until dropped.
#[derive(Debug)]
pub struct Reservation {
    pending: Option<(Arc<AtomicU64>, u64)>,
}

impl Reservation {
    pub(super) fn new(counter: Arc<AtomicU64>, bytes: u64) -> Self {
        counter.fetch_add(bytes, Ordering::SeqCst);
        Self {
            pending: Some((counter, bytes)),
        }
    }

    /// Holds nothing; for a deployment with no ceiling.
    pub fn none() -> Self {
        Self { pending: None }
    }
}

impl Drop for Reservation {
    fn drop(&mut self) {
        if let Some((counter, bytes)) = self.pending.take() {
            counter.fetch_sub(bytes, Ordering::SeqCst);
        }
    }
}
