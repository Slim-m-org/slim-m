// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Startup pass deciding which mention rows from before migration 0203 were a direct `@username`.

use crate::store::Store;

/// Runs [`Store::backfill_mention_directness`] once in the background; a failure is logged and
/// retried on the next start, since undecided rows stay marked.
pub(crate) fn spawn_mention_directness_backfill(store: Store) {
    tokio::spawn(async move {
        match store.backfill_mention_directness().await {
            Ok(0) => {}
            Ok(count) => tracing::info!(count, "decided which older mentions were direct"),
            Err(err) => tracing::warn!(error = %err, "mention directness backfill failed"),
        }
    });
}
