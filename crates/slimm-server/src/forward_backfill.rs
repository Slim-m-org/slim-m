// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Startup pass for forwarded copies whose original was deleted before copies followed it.

use crate::media::Media;
use crate::store::Store;

/// Runs [`Store::backfill_orphaned_forwards`] once in the background, then
/// reclaims the attachment files it freed. Failures are logged, never fatal.
pub(crate) fn spawn_forward_backfill(store: Store, media: Media) {
    tokio::spawn(async move {
        let cascade = match store.backfill_orphaned_forwards().await {
            Ok(cascade) => cascade,
            Err(err) => {
                tracing::warn!(error = %err, "forward backfill failed");
                return;
            }
        };
        if !cascade.deleted.is_empty() || !cascade.detached.is_empty() {
            tracing::info!(
                deleted = cascade.deleted.len(),
                detached = cascade.detached.len(),
                "removed forwarded copies of originals deleted earlier"
            );
        }
        for hex in cascade
            .deleted
            .into_iter()
            .flat_map(|c| c.freed_attachments)
        {
            crate::blobs::release(&store, &media, &hex).await;
        }
    });
}
