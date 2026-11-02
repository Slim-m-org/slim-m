// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One press at a time per shared surface.
//!
//! A press reads the stored frame, runs the module on it and stores the result.
//! Two presses that overlap would both start from the same frame and the later
//! store would erase the earlier press. Holding this lock across the whole
//! read-run-store makes each press start from the frame the previous one left.
//! The server is a single process, so an in-memory lock is enough.

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};

use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};

use crate::ids::MessageId;

static LOCKS: LazyLock<Mutex<HashMap<MessageId, Arc<AsyncMutex<()>>>>> =
    LazyLock::new(Mutex::default);

/// Waits for the surface's turn; the turn ends when the guard is dropped.
pub(super) async fn lock_surface(message: MessageId) -> OwnedMutexGuard<()> {
    let lock = {
        let mut locks = LOCKS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // An idle surface has no waiter holding its lock, so its entry can go.
        locks.retain(|_, lock| Arc::strong_count(lock) > 1);
        Arc::clone(locks.entry(message).or_default())
    };
    lock.lock_owned().await
}
