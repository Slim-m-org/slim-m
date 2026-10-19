// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bounded-size previews of still images, derived once from the stored bytes.
//!
//! An attachment is content addressed and immutable, so a preview never goes
//! stale: it is written next to the blob on first request and removed with it.
//! Decoding is the one place the server holds a whole raster in memory, so
//! [`Previews`] admits a single generation at a time and refuses pictures too big to decode.
//! A picture that animates gets a first-frame still at each bucket instead.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::Media;
use super::memory_budget::MemoryBudget;
pub use super::preview_derive::Variant;
use super::preview_derive::{decode_estimate, derive_many, derive_one, variant_of};

/// Longest-side widths a preview may be asked for. Bucketing bounds the files kept per attachment.
pub const BUCKETS: [u32; 3] = [320, 640, 1280];

/// Uploads waiting to be previewed ahead of any request; past this the rest are left to be derived on demand.
const MAX_PREWARM_QUEUE: usize = 8;

/// The bucket used when a caller does not name one.
pub const DEFAULT_BUCKET: u32 = 640;

/// What a preview request resolves to.
#[derive(Debug)]
pub enum Preview {
    /// Serve the stored original: animated, too big to decode, or no smaller as a preview.
    Original,
    /// Serve this derived file.
    Derived(PathBuf),
}

/// Where previews live and the gate that bounds decode memory.
#[derive(Debug, Clone)]
pub struct Previews {
    dir: PathBuf,
    gate: Arc<Semaphore>,
    prewarming: Arc<AtomicUsize>,
    /// The process-wide memory budget compression draws on too.
    budget: MemoryBudget,
}

impl Media {
    /// Starts deriving the previews of a stored upload when it is a still picture they apply to.
    pub fn prewarm_preview(&self, hex: &str, content_type: &str) {
        if matches!(
            content_type,
            "image/jpeg" | "image/png" | "image/webp" | "image/gif"
        ) {
            self.previews
                .prewarm(hex.to_owned(), self.attachment_file(hex));
        }
    }
}

/// The bucket a requested width rounds up to, or the largest when it exceeds them all.
pub fn bucket_for(width: u32) -> u32 {
    BUCKETS
        .into_iter()
        .find(|bucket| width <= *bucket)
        .unwrap_or(BUCKETS[BUCKETS.len() - 1])
}

impl Previews {
    pub(super) fn new(dir: PathBuf, budget: MemoryBudget) -> Self {
        Self {
            dir,
            gate: Arc::new(Semaphore::new(1)),
            prewarming: Arc::new(AtomicUsize::new(0)),
            budget,
        }
    }

    pub(super) fn use_budget(&mut self, budget: MemoryBudget) {
        self.budget = budget;
    }

    /// Memory for decoding `original`, held until dropped. `Ok(None)` when the file will not be
    /// decoded at all; `Err` when the budget has no room, so the original is the answer.
    async fn reserve(
        &self,
        original: &Path,
        variant: Variant,
    ) -> Result<Option<OwnedSemaphorePermit>, ()> {
        let Some(estimate) = decode_estimate(original, variant).await else {
            return Ok(None);
        };
        self.budget.admit(estimate).await.map(Some).ok_or(())
    }

    fn path(&self, hex: &str, variant: Variant, bucket: u32) -> PathBuf {
        self.dir.join(format!("{hex}.{}{bucket}", variant.tag()))
    }

    /// The variant a request for a still should be answered with: the first frame of a picture
    /// that animates, the ordinary preview of any other.
    pub async fn variant_for(&self, original: &Path) -> Variant {
        variant_of(original).await
    }

    /// Resolves the preview of `original` at `bucket`, generating it on first use.
    ///
    /// An empty derived file records that the original is the answer, so a
    /// picture that cannot or need not shrink is judged once, not per request.
    pub async fn resolve(
        &self,
        hex: &str,
        original: &Path,
        bucket: u32,
        variant: Variant,
    ) -> io::Result<Preview> {
        let derive = move |original: &Path, bucket| derive_one(original, variant, bucket);
        self.resolve_with(hex, original, bucket, variant, derive)
            .await
    }

    /// The permit moves into the blocking task, so a cancelled request cannot free the gate
    /// while its decode is still running.
    async fn resolve_with<F>(
        &self,
        hex: &str,
        original: &Path,
        bucket: u32,
        variant: Variant,
        derive: F,
    ) -> io::Result<Preview>
    where
        F: FnOnce(&Path, u32) -> io::Result<Option<Vec<u8>>> + Send + 'static,
    {
        let path = self.path(hex, variant, bucket);
        if let Some(found) = existing(&path).await? {
            return Ok(found);
        }
        let permit = Arc::clone(&self.gate)
            .acquire_owned()
            .await
            .map_err(io::Error::other)?;
        if let Some(found) = existing(&path).await? {
            return Ok(found);
        }
        let Ok(memory) = self.reserve(original, variant).await else {
            return Ok(Preview::Original);
        };
        let original = original.to_path_buf();
        let target = path.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = (permit, memory);
            let derived = derive(&original, bucket)?;
            write_atomic(&target, derived.as_deref().unwrap_or_default())?;
            Ok(derived.map_or(Preview::Original, |_| Preview::Derived(target)))
        })
        .await
        .unwrap_or_else(|e| Err(io::Error::other(e)))
    }

    /// Derives every bucket of a just-uploaded picture from one decode, in the background.
    ///
    /// The first viewer of a photo then finds its preview waiting instead of queueing behind a
    /// decode, and the gate still admits one raster at a time. A backlog past
    /// [`MAX_PREWARM_QUEUE`] is skipped, since those pictures are derived when first requested.
    pub fn prewarm(&self, hex: String, original: PathBuf) {
        if self.prewarming.fetch_add(1, Ordering::AcqRel) >= MAX_PREWARM_QUEUE {
            self.prewarming.fetch_sub(1, Ordering::AcqRel);
            return;
        }
        let previews = self.clone();
        tokio::spawn(async move {
            if let Err(err) = previews.fill_buckets(&hex, &original).await {
                tracing::warn!(error = %err, attachment = %hex, "could not prewarm attachment previews");
            }
            previews.prewarming.fetch_sub(1, Ordering::AcqRel);
        });
    }

    async fn fill_buckets(&self, hex: &str, original: &Path) -> io::Result<()> {
        let permit = Arc::clone(&self.gate)
            .acquire_owned()
            .await
            .map_err(io::Error::other)?;
        let variant = variant_of(original).await;
        let mut missing = Vec::new();
        for bucket in BUCKETS {
            if existing(&self.path(hex, variant, bucket)).await?.is_none() {
                missing.push(bucket);
            }
        }
        if missing.is_empty() {
            return Ok(());
        }
        let Ok(memory) = self.reserve(original, variant).await else {
            return Ok(());
        };
        let original = original.to_path_buf();
        let targets: Vec<(u32, PathBuf)> = missing
            .into_iter()
            .map(|bucket| (bucket, self.path(hex, variant, bucket)))
            .collect();
        tokio::task::spawn_blocking(move || {
            let _permit = (permit, memory);
            let buckets: Vec<u32> = targets.iter().map(|(bucket, _)| *bucket).collect();
            let derived = derive_many(&original, variant, &buckets)?;
            for ((_, target), bytes) in targets.iter().zip(derived) {
                write_atomic(target, bytes.as_deref().unwrap_or_default())?;
            }
            Ok(())
        })
        .await
        .unwrap_or_else(|e| Err(io::Error::other(e)))
    }

    /// Removes every preview of `hex`.
    pub async fn delete(&self, hex: &str) -> io::Result<()> {
        let dir = self.dir.clone();
        let prefix = format!("{hex}.");
        tokio::task::spawn_blocking(move || {
            for entry in std::fs::read_dir(dir)? {
                let entry = entry?;
                if entry.file_name().to_string_lossy().starts_with(&prefix) {
                    std::fs::remove_file(entry.path())?;
                }
            }
            Ok(())
        })
        .await
        .unwrap_or_else(|e| Err(io::Error::other(e)))
    }

    /// Every preview file name with when it was last written, for the leak scan.
    pub async fn files(&self) -> io::Result<Vec<(String, std::time::SystemTime)>> {
        let dir = self.dir.clone();
        tokio::task::spawn_blocking(move || {
            let mut files = Vec::new();
            for entry in std::fs::read_dir(dir)? {
                let entry = entry?;
                if let Some(name) = entry.file_name().to_str() {
                    files.push((name.to_owned(), entry.metadata()?.modified()?));
                }
            }
            Ok(files)
        })
        .await
        .unwrap_or_else(|e| Err(io::Error::other(e)))
    }

    pub async fn remove_file(&self, name: &str) -> io::Result<()> {
        if name.contains('/') {
            return Err(io::Error::other("not a preview file name"));
        }
        let path = self.dir.join(name);
        tokio::task::spawn_blocking(move || std::fs::remove_file(path))
            .await
            .unwrap_or_else(|e| Err(io::Error::other(e)))
    }
}

async fn existing(path: &Path) -> io::Result<Option<Preview>> {
    match tokio::fs::metadata(path).await {
        Ok(meta) if meta.len() == 0 => Ok(Some(Preview::Original)),
        Ok(_) => Ok(Some(Preview::Derived(path.to_path_buf()))),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));
    let tmp = dir.join(format!(".tmp-{}", uuid::Uuid::now_v7()));
    let placed = std::fs::write(&tmp, bytes).and_then(|()| std::fs::rename(&tmp, path));
    if placed.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    placed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::Media;
    use image::ExtendedColorType;
    use image::codecs::jpeg::JpegEncoder;

    fn big_jpeg() -> Vec<u8> {
        let img = image::RgbImage::from_fn(1600, 1200, |x, y| {
            image::Rgb([(x ^ y) as u8, (x * 3) as u8, (y * 7) as u8])
        });
        let mut out = Vec::new();
        JpegEncoder::new_with_quality(&mut out, 95)
            .encode(img.as_raw(), 1600, 1200, ExtendedColorType::Rgb8)
            .unwrap();
        out
    }

    #[tokio::test]
    async fn a_cancelled_request_keeps_the_gate_until_its_decode_finishes() {
        let previews = Previews::new(
            std::env::temp_dir().join(format!("slimm-preview-{}", uuid::Uuid::now_v7())),
            MemoryBudget::for_limit(None),
        );
        std::fs::create_dir_all(&previews.dir).unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();

        let first = previews.clone();
        let request = tokio::spawn(async move {
            first
                .resolve_with("aa", Path::new("x"), 320, Variant::Preview, move |_, _| {
                    started_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    Ok(None)
                })
                .await
        });
        tokio::task::spawn_blocking(move || started_rx.recv().unwrap())
            .await
            .unwrap();
        request.abort();
        let _ = request.await;

        assert_eq!(
            previews.gate.available_permits(),
            0,
            "the decode still holds the gate"
        );
        release_tx.send(()).unwrap();
        let _free =
            tokio::time::timeout(std::time::Duration::from_secs(5), previews.gate.acquire())
                .await
                .expect("the gate frees once the decode ends")
                .unwrap();
        std::fs::remove_dir_all(&previews.dir).unwrap();
    }

    #[test]
    fn widths_round_up_to_a_bucket_and_cap_at_the_largest() {
        assert_eq!(bucket_for(1), 320);
        assert_eq!(bucket_for(321), 640);
        assert_eq!(bucket_for(641), 1280);
        assert_eq!(bucket_for(u32::MAX), 1280);
    }

    #[tokio::test]
    async fn deleting_an_attachment_removes_its_previews() {
        let media = Media::for_tests();
        let hex = "ab".repeat(32);
        media.write_attachment(&hex, big_jpeg()).await.unwrap();
        let resolved = media
            .previews()
            .resolve(&hex, &media.attachment_file(&hex), 640, Variant::Preview)
            .await
            .unwrap();
        assert!(matches!(resolved, Preview::Derived(_)));
        assert_eq!(media.previews().files().await.unwrap().len(), 1);

        media.delete_attachment(&hex).await.unwrap();

        assert!(media.previews().files().await.unwrap().is_empty());
    }
}
