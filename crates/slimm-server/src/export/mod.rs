// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Data exports: a member's own data and a whole space, written as one tar
//! archive by a background job.
//!
//! A job first writes small JSON and JSON-lines sections to a scratch
//! directory, one database stream at a time, then streams them and the
//! attachment files into the archive behind a manifest. Memory use does not
//! grow with the data. `docs/data-export-format.md` is the format reference.

mod build;
mod member;
mod space;
mod sweep;
mod tar;

use tokio::sync::Semaphore;

use crate::ids::{ExportId, UserId};
use crate::media::Media;
use crate::store::{ExportKind, Store};

pub use sweep::{spawn_export_sweep, sweep_exports_once};

/// The archive layout this server writes; bump on any change an importer would notice.
pub const FORMAT_VERSION: u32 = 1;
/// The manifest's `format` value.
pub const FORMAT_NAME: &str = "slimm-export";

/// One archive is built at a time, so exports cannot starve the server of disk or database reads.
static BUILDING: Semaphore = Semaphore::const_new(1);

/// The refusal shown when a job fails; the cause goes to the log.
const FAILURE: &str = "the export could not be finished";

#[derive(Debug)]
struct Gone;

impl std::fmt::Display for Gone {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the export was cancelled")
    }
}

impl std::error::Error for Gone {}

/// What a queued job needs to run.
#[derive(Debug, Clone, Copy)]
pub struct Job {
    pub id: ExportId,
    pub user_id: UserId,
    pub kind: ExportKind,
}

/// Starts `job` in the background; returns at once.
pub fn spawn(store: Store, media: Media, job: Job) {
    tokio::spawn(async move { run(store, media, job).await });
}

/// Builds the archive for `job` and records how it went.
pub async fn run(store: Store, media: Media, job: Job) {
    let Ok(_permit) = BUILDING.acquire().await else {
        return;
    };
    if let Err(err) = store.mark_export_running(job.id).await {
        tracing::warn!(%err, "could not mark an export running");
    }
    let id = job.id.to_string();
    let outcome = build_archive(&store, &media, job).await;
    let _ = media.remove_export_work(&id).await;
    match outcome {
        Ok(size) => finish(&store, &media, job, size).await,
        Err(err) => {
            let _ = media.remove_export(&id).await;
            if err.downcast_ref::<Gone>().is_none() {
                tracing::warn!(%err, export = %id, "a data export failed");
                let _ = store.mark_export_failed(job.id, FAILURE).await;
            }
        }
    }
}

async fn finish(store: &Store, media: &Media, job: Job, size: u64) {
    let id = job.id.to_string();
    let size = i64::try_from(size).unwrap_or(i64::MAX);
    match store.mark_export_ready(job.id, size).await {
        Ok(true) => {}
        _ => {
            let _ = media.remove_export(&id).await;
        }
    }
}

async fn build_archive(store: &Store, media: &Media, job: Job) -> anyhow::Result<u64> {
    let mut builder = build::Builder::new(store, media, job.id).await?;
    match job.kind {
        ExportKind::Member => member::collect(&mut builder, job.user_id).await?,
        ExportKind::Space => space::collect(&mut builder).await?,
    }
    builder.assemble(job.kind, job.user_id).await
}
