// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Collecting sections into a scratch directory and assembling the archive.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::Context;
use serde_json::{Value, json};
use tokio::fs::File;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter};

use super::tar::TarWriter;
use super::{FORMAT_NAME, FORMAT_VERSION, Gone};
use crate::ids::{ExportId, UserId};
use crate::media::Media;
use crate::store::RowStream;
use crate::store::{ExportKind, Store};

/// Progress is written at most this often.
const PROGRESS_EVERY: Duration = Duration::from_secs(1);
/// The most missing attachment ids the report lists.
const MAX_REPORTED_MISSING: usize = 1000;
const ATTACHMENT_INDEX: &str = "attachments.jsonl";

struct Entry {
    path: String,
    format: &'static str,
    rows: Option<u64>,
    description: &'static str,
    source: PathBuf,
}

pub(super) struct Builder<'a> {
    store: &'a Store,
    media: &'a Media,
    id: ExportId,
    work: PathBuf,
    entries: Vec<Entry>,
    not_included: Vec<&'static str>,
    total: u64,
    processed: u64,
    last_report: Instant,
}

impl<'a> Builder<'a> {
    pub(super) async fn new(
        store: &'a Store,
        media: &'a Media,
        id: ExportId,
    ) -> anyhow::Result<Self> {
        let work = media.export_work_dir(&id.to_string());
        tokio::fs::create_dir_all(&work).await?;
        Ok(Self {
            store,
            media,
            id,
            work,
            entries: Vec::new(),
            not_included: Vec::new(),
            total: 0,
            processed: 0,
            last_report: Instant::now(),
        })
    }

    pub(super) fn store(&self) -> &Store {
        self.store
    }

    pub(super) fn media(&self) -> &Media {
        self.media
    }

    pub(super) fn not_included(&mut self, items: &[&'static str]) {
        self.not_included.extend_from_slice(items);
    }

    pub(super) async fn set_total(&mut self, total: u64) -> anyhow::Result<()> {
        self.total = total;
        self.report().await
    }

    /// Counts `n` finished items and writes progress when enough has passed.
    pub(super) async fn advance(&mut self, n: u64) -> anyhow::Result<()> {
        self.processed += n;
        if self.last_report.elapsed() >= PROGRESS_EVERY {
            self.report().await?;
        }
        Ok(())
    }

    async fn report(&mut self) -> anyhow::Result<()> {
        self.last_report = Instant::now();
        let processed = i64::try_from(self.processed)?;
        let total = i64::try_from(self.total.max(self.processed))?;
        if self
            .store
            .set_export_progress(self.id, processed, total)
            .await?
        {
            Ok(())
        } else {
            Err(Gone.into())
        }
    }

    fn scratch_path(&self) -> PathBuf {
        self.work.join(format!("{:05}.part", self.entries.len()))
    }

    pub(super) async fn json(
        &mut self,
        path: &str,
        description: &'static str,
        value: &Value,
    ) -> anyhow::Result<()> {
        let source = self.scratch_path();
        tokio::fs::write(&source, serde_json::to_vec_pretty(value)?).await?;
        self.entries.push(Entry {
            path: path.to_owned(),
            format: "json",
            rows: None,
            description,
            source,
        });
        Ok(())
    }

    pub(super) async fn binary(
        &mut self,
        path: &str,
        description: &'static str,
        bytes: &[u8],
    ) -> anyhow::Result<()> {
        let source = self.scratch_path();
        tokio::fs::write(&source, bytes).await?;
        self.entries.push(Entry {
            path: path.to_owned(),
            format: "binary",
            rows: None,
            description,
            source,
        });
        Ok(())
    }

    /// Writes a stream of rows as JSON lines; returns the row count.
    ///
    /// An empty set is written too unless `skip_empty`, so a reader can tell
    /// "nothing" from "not exported".
    pub(super) async fn jsonl(
        &mut self,
        path: &str,
        description: &'static str,
        mut rows: RowStream,
        opts: Rows,
    ) -> anyhow::Result<u64> {
        let source = self.scratch_path();
        let mut out = BufWriter::new(File::create(&source).await?);
        let mut count = 0u64;
        while let Some(item) = rows.recv().await {
            let mut line = serde_json::to_vec(&item?)?;
            line.push(b'\n');
            out.write_all(&line).await?;
            count += 1;
            if opts.track {
                self.advance(1).await?;
            }
        }
        out.flush().await?;
        if count == 0 && opts.skip_empty {
            tokio::fs::remove_file(&source).await?;
            return Ok(0);
        }
        self.entries.push(Entry {
            path: path.to_owned(),
            format: "jsonl",
            rows: Some(count),
            description,
            source,
        });
        Ok(count)
    }

    /// Writes the archive and returns its size in bytes.
    pub(super) async fn assemble(
        mut self,
        kind: ExportKind,
        subject: UserId,
    ) -> anyhow::Result<u64> {
        let id = self.id.to_string();
        let part = self.media.export_part_path(&id);
        let out = BufWriter::new(File::create(&part).await?);
        let mut tar = TarWriter::new(out, crate::store::now_ms().unsigned_abs() / 1000);
        let manifest = self.manifest(kind, subject).await?;
        tar.append_bytes("manifest.json", &serde_json::to_vec_pretty(&manifest)?)
            .await?;
        tar.append_bytes("README.txt", self.readme(kind).as_bytes())
            .await?;
        let index = self
            .entries
            .iter()
            .find(|e| e.path == ATTACHMENT_INDEX)
            .map(|e| e.source.clone());
        for entry in std::mem::take(&mut self.entries) {
            tar.append_file(&entry.path, &entry.source).await?;
        }
        let missing = self.append_attachments(&mut tar, index).await?;
        tar.append_bytes(
            "report.json",
            &serde_json::to_vec_pretty(&json!({ "attachments_missing": missing }))?,
        )
        .await?;
        let size = tar.finish().await?;
        tokio::fs::rename(&part, self.media.export_archive_path(&id)).await?;
        self.report().await?;
        Ok(size)
    }

    async fn manifest(&self, kind: ExportKind, subject: UserId) -> anyhow::Result<Value> {
        let files: Vec<Value> = self
            .entries
            .iter()
            .map(|e| {
                json!({ "path": e.path, "format": e.format, "rows": e.rows, "description": e.description })
            })
            .collect();
        let mut manifest = json!({
            "format": FORMAT_NAME,
            "format_version": FORMAT_VERSION,
            "kind": kind.as_str(),
            "created_at": crate::store::now_ms(),
            "server_version": env!("CARGO_PKG_VERSION"),
            "files": files,
            "attachments": { "index": ATTACHMENT_INDEX, "directory": "attachments/" },
            "not_included": self.not_included,
        });
        if kind == ExportKind::Member {
            manifest["subject_user_id"] = json!(subject.to_string());
        } else {
            manifest["space_name"] = json!(self.store.deployment_name().await?);
        }
        Ok(manifest)
    }

    fn readme(&self, kind: ExportKind) -> String {
        let intro = match kind {
            ExportKind::Member => "Your data from a slim-m space.",
            ExportKind::Space => "A slim-m space, exported by an administrator.",
        };
        let mut text = format!(
            "{intro}\nFormat: {FORMAT_NAME} version {FORMAT_VERSION}. See manifest.json.\n\nFiles:\n"
        );
        for entry in &self.entries {
            text.push_str(&format!("  {} - {}\n", entry.path, entry.description));
        }
        text.push_str(
            "  attachments/<sha256> - file bytes, indexed by attachments.jsonl\n\nNot included:\n",
        );
        for item in &self.not_included {
            text.push_str(&format!("  {item}\n"));
        }
        text
    }

    /// Streams every file the attachment index names; returns the ids that had vanished.
    async fn append_attachments(
        &mut self,
        tar: &mut TarWriter<BufWriter<File>>,
        index: Option<PathBuf>,
    ) -> anyhow::Result<Vec<String>> {
        let mut missing = Vec::new();
        let Some(index) = index else {
            return Ok(missing);
        };
        let mut lines = BufReader::new(File::open(index).await?).lines();
        while let Some(line) = lines.next_line().await? {
            let row: Value = serde_json::from_str(&line)?;
            let sha = row["sha256"]
                .as_str()
                .context("an attachment row has no sha256")?;
            match self.media.open_attachment(sha).await {
                Ok((file, len)) => {
                    tar.append_reader(&format!("attachments/{sha}"), file, len)
                        .await?
                }
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                    if missing.len() < MAX_REPORTED_MISSING {
                        missing.push(sha.to_owned());
                    }
                }
                Err(err) => return Err(err.into()),
            }
            self.advance(1).await?;
        }
        Ok(missing)
    }
}

/// How a section's rows are counted and kept.
#[derive(Clone, Copy, Default)]
pub(super) struct Rows {
    /// Rows count toward the job's progress.
    pub track: bool,
    /// An empty set leaves no file.
    pub skip_empty: bool,
}
