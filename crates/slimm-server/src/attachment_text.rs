// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Background extraction of attachment text for search.
//!
//! Off the request path on purpose: an upload or a send never waits on it. One
//! sweep finds attachments that are in a message and not yet processed, newest
//! first, which covers new uploads and the backfill of old ones with the same
//! code. Files are handled one at a time, reading at most the per-kind byte
//! limit, so memory stays flat however many arrive at once. PDFs are parsed in
//! a resource-limited child process (see [`pdf_worker`]); an encrypted,
//! oversized, hostile or scanned PDF simply yields no text. There is no OCR.
//!
//! A file is marked processed before a PDF is parsed, so a crash mid-parse
//! cannot repeat on restart. A failure that may pass (an unreadable blob, a
//! worker that would not start) is never recorded and is retried with
//! growing backoff.

mod extract;
mod pdf_worker;
mod retry;

use std::sync::Arc;
use std::time::Duration;

use tokio::io::AsyncReadExt;

use crate::media::Media;
use crate::store::{Store, TextCandidate};
use extract::{Kind, extract, kind_of};
pub use pdf_worker::{Limit, PdfParse, PdfWorker, WORKER_ARG, run_pdf_worker};
use retry::Retries;

const SWEEP_INTERVAL: Duration = Duration::from_secs(45);
const BATCH: i64 = 20;
const MAX_PER_PASS: usize = 200;
const PAUSE_BETWEEN_FILES: Duration = Duration::from_millis(50);
const RETRY_BACKOFF: Duration = Duration::from_secs(60);

/// What one attachment's extraction came to.
enum Outcome {
    Text(String),
    NothingToExtract,
    RetryLater,
}

/// The sweep's state: how to run the PDF worker and which files are backing off.
pub struct TextExtractor {
    worker: Option<PdfWorker>,
    retries: Retries,
}

impl TextExtractor {
    /// The server's own extractor: PDFs parse in a child of this binary.
    pub fn new() -> Self {
        Self::with_worker(PdfWorker::current_exe().ok(), RETRY_BACKOFF)
    }

    /// An extractor with an explicit worker, for tests; `None` leaves PDFs to retry.
    pub fn with_worker(worker: Option<PdfWorker>, retry_backoff: Duration) -> Self {
        Self {
            worker,
            retries: Retries::new(retry_backoff),
        }
    }

    /// One pass: extracts up to a bounded number of waiting attachments and
    /// returns how many it settled.
    pub async fn run_pass(&self, store: &Store, media: &Media) -> usize {
        let (mut attempted, mut done) = (0, 0);
        while attempted < MAX_PER_PASS {
            let batch = match store
                .attachments_awaiting_text(BATCH, &self.retries.waiting())
                .await
            {
                Ok(batch) if !batch.is_empty() => batch,
                Ok(_) => break,
                Err(err) => {
                    tracing::warn!(error = %err, "attachment text lookup failed");
                    break;
                }
            };
            for candidate in batch {
                if self.process(store, media, &candidate).await {
                    done += 1;
                }
                attempted += 1;
                tokio::time::sleep(PAUSE_BETWEEN_FILES).await;
            }
        }
        done
    }

    async fn process(&self, store: &Store, media: &Media, candidate: &TextCandidate) -> bool {
        let text = match self.text_of(store, media, candidate).await {
            Outcome::Text(text) => Some(text),
            Outcome::NothingToExtract => None,
            Outcome::RetryLater => {
                self.retries.failed(&candidate.sha256);
                return false;
            }
        };
        self.retries.settled(&candidate.sha256);
        if let Err(err) = store
            .record_attachment_text(&candidate.sha256, text.as_deref())
            .await
        {
            tracing::warn!(error = %err, attachment = %candidate.hex, "could not store attachment text");
        }
        true
    }

    async fn text_of(&self, store: &Store, media: &Media, candidate: &TextCandidate) -> Outcome {
        let Some(kind) = kind_of(candidate.filename.as_deref(), &candidate.content_type) else {
            return Outcome::NothingToExtract;
        };
        if kind == Kind::Pdf && candidate.size as u64 > kind.read_limit() {
            return Outcome::NothingToExtract;
        }
        let Ok((file, _)) = media.open_attachment(&candidate.hex).await else {
            return Outcome::RetryLater;
        };
        let mut bytes = Vec::new();
        if file
            .take(kind.read_limit())
            .read_to_end(&mut bytes)
            .await
            .is_err()
        {
            return Outcome::RetryLater;
        }
        match kind {
            Kind::Text => extract(kind, &bytes).map_or(Outcome::NothingToExtract, Outcome::Text),
            Kind::Pdf => self.pdf_text_of(store, candidate, bytes).await,
        }
    }

    async fn pdf_text_of(
        &self,
        store: &Store,
        candidate: &TextCandidate,
        bytes: Vec<u8>,
    ) -> Outcome {
        let Some(worker) = &self.worker else {
            return Outcome::RetryLater;
        };
        let mark_attempted = || async {
            if let Err(err) = store.record_attachment_text(&candidate.sha256, None).await {
                tracing::warn!(error = %err, attachment = %candidate.hex, "could not mark attachment attempted");
            }
        };
        match worker.parse(bytes, mark_attempted).await {
            PdfParse::Text(text) => Outcome::Text(text),
            PdfParse::NoText => Outcome::NothingToExtract,
            PdfParse::Limited(limit) => {
                tracing::info!(attachment = %candidate.hex, ?limit, "pdf worker stopped; nothing extracted");
                Outcome::NothingToExtract
            }
            PdfParse::Unavailable => Outcome::RetryLater,
        }
    }
}

impl Default for TextExtractor {
    fn default() -> Self {
        Self::new()
    }
}

pub(crate) fn spawn_attachment_text_sweep(store: Store, media: Media) {
    let extractor = Arc::new(TextExtractor::new());
    crate::sweeps::spawn_sweep(SWEEP_INTERVAL, move || {
        let (store, media, extractor) = (store.clone(), media.clone(), extractor.clone());
        async move {
            extractor.run_pass(&store, &media).await;
        }
    });
}
