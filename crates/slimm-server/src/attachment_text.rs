// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Background extraction of attachment text for search.
//!
//! Off the request path on purpose: an upload or a send never waits on it. One
//! sweep finds attachments that are in a message and not yet processed, newest
//! first, which covers new uploads and the backfill of old ones with the same
//! code. Files are handled one at a time, reading at most the per-kind byte
//! limit, so memory stays flat however many arrive at once. PDFs parse on a
//! blocking thread under a timeout; an encrypted, oversized or scanned PDF
//! simply yields no text. There is no OCR.

mod extract;

use std::time::Duration;

use tokio::io::AsyncReadExt;

use crate::media::Media;
use crate::store::{Store, TextCandidate};
use extract::{Kind, extract, kind_of};

const SWEEP_INTERVAL: Duration = Duration::from_secs(45);
const BATCH: i64 = 20;
const MAX_PER_PASS: usize = 200;
const PDF_TIMEOUT: Duration = Duration::from_secs(20);
const PAUSE_BETWEEN_FILES: Duration = Duration::from_millis(50);

pub(crate) fn spawn_attachment_text_sweep(store: Store, media: Media) {
    crate::sweeps::spawn_sweep(SWEEP_INTERVAL, move || {
        let store = store.clone();
        let media = media.clone();
        async move {
            run_attachment_text_pass(&store, &media).await;
        }
    });
}

/// One pass: extracts up to a bounded number of waiting attachments and
/// returns how many it processed.
pub async fn run_attachment_text_pass(store: &Store, media: &Media) -> usize {
    let mut done = 0;
    while done < MAX_PER_PASS {
        let batch = match store.attachments_awaiting_text(BATCH).await {
            Ok(batch) if !batch.is_empty() => batch,
            Ok(_) => break,
            Err(err) => {
                tracing::warn!(error = %err, "attachment text lookup failed");
                break;
            }
        };
        for candidate in batch {
            process(store, media, &candidate).await;
            done += 1;
            tokio::time::sleep(PAUSE_BETWEEN_FILES).await;
        }
    }
    done
}

async fn process(store: &Store, media: &Media, candidate: &TextCandidate) {
    let text = text_of(media, candidate).await;
    if let Err(err) = store
        .record_attachment_text(&candidate.sha256, text.as_deref())
        .await
    {
        tracing::warn!(error = %err, attachment = %candidate.hex, "could not store attachment text");
    }
}

async fn text_of(media: &Media, candidate: &TextCandidate) -> Option<String> {
    let kind = kind_of(candidate.filename.as_deref(), &candidate.content_type)?;
    if kind == Kind::Pdf && candidate.size as u64 > kind.read_limit() {
        return None;
    }
    let (file, _) = media.open_attachment(&candidate.hex).await.ok()?;
    let mut bytes = Vec::new();
    file.take(kind.read_limit())
        .read_to_end(&mut bytes)
        .await
        .ok()?;
    match kind {
        Kind::Text => extract(kind, &bytes),
        Kind::Pdf => {
            let parse = tokio::task::spawn_blocking(move || extract(kind, &bytes));
            tokio::time::timeout(PDF_TIMEOUT, parse).await.ok()?.ok()?
        }
    }
}
