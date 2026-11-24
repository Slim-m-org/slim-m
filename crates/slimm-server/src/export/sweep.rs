// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting archives once they expire, and any file no job row wants.

use std::time::Duration;

use crate::ids::ExportId;
use crate::media::Media;
use crate::store::{Store, now_ms};

/// How often expired archives are looked for; an hour of slack on a day's life is fine.
const SWEEP_INTERVAL: Duration = Duration::from_secs(10 * 60);

/// Runs [`sweep_exports_once`] on a timer for the life of the process.
pub fn spawn_export_sweep(store: Store, media: Media) {
    tokio::spawn(async move {
        resume_interrupted_exports(&store, &media).await;
        let mut ticker = tokio::time::interval(SWEEP_INTERVAL);
        loop {
            ticker.tick().await;
            if let Err(err) = sweep_exports_once(&store, &media).await {
                tracing::warn!(%err, "export sweep failed");
            }
        }
    });
}

/// Re-runs every export a restart cut short; a row too old to matter is failed by the staleness rule.
async fn resume_interrupted_exports(store: &Store, media: &Media) {
    let jobs = match store.requeue_interrupted_exports().await {
        Ok(jobs) => jobs,
        Err(err) => {
            tracing::warn!(%err, "could not requeue interrupted exports");
            return;
        }
    };
    for export in jobs {
        let _ = media.remove_export(&export.id.to_string()).await;
        super::spawn(
            store.clone(),
            media.clone(),
            super::Job {
                id: export.id,
                user_id: export.user_id,
                kind: export.kind,
            },
        );
    }
}

/// Expires due archives and removes files no queued, running or ready job owns.
pub async fn sweep_exports_once(store: &Store, media: &Media) -> anyhow::Result<()> {
    for id in store.expire_data_exports(now_ms()).await? {
        media.remove_export(&id.to_string()).await?;
    }
    for name in media.export_ids_on_disk().await? {
        let wanted = match uuid::Uuid::parse_str(&name) {
            Ok(id) => store.export_file_is_wanted(ExportId(id)).await?,
            Err(_) => false,
        };
        if !wanted {
            media.remove_export(&name).await?;
        }
    }
    Ok(())
}
