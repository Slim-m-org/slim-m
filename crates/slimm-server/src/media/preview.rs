// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bounded-size previews of still images, derived once from the stored bytes.
//!
//! An attachment is content addressed and immutable, so a preview never goes
//! stale: it is written next to the blob on first request and removed with it.
//! Decoding is the one place the server holds a whole raster in memory, so
//! [`Previews`] admits a single generation at a time and refuses pictures past
//! [`MAX_SOURCE_PIXELS`] or [`MAX_SOURCE_BYTES`].

use std::io::{self, Cursor};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use image::codecs::jpeg::JpegEncoder;
use image::codecs::webp::WebPEncoder;
use image::metadata::Orientation;
use image::{DynamicImage, ExtendedColorType, ImageDecoder, ImageReader, Limits};
use tokio::sync::Semaphore;

use super::Media;
use super::image_header::inspect;
use super::preview_scale::fit;

/// Longest-side widths a preview may be asked for. Bucketing bounds the files kept per attachment.
pub const BUCKETS: [u32; 3] = [320, 640, 1280];

/// Uploads waiting to be previewed ahead of any request; past this the rest are left to be derived on demand.
const MAX_PREWARM_QUEUE: usize = 8;

/// The bucket used when a caller does not name one.
pub const DEFAULT_BUCKET: u32 = 640;

/// Pictures with more pixels are served as the original instead of decoded.
const MAX_SOURCE_PIXELS: u64 = 40_000_000;

/// Files larger than this are served as the original instead of read into memory.
const MAX_SOURCE_BYTES: u64 = 48 * 1024 * 1024;

/// The decoder's allocation ceiling: an RGB raster at [`MAX_SOURCE_PIXELS`] plus working room.
const DECODE_ALLOC_LIMIT: u64 = 192 * 1024 * 1024;

/// How much of the file is read to learn its dimensions before deciding to decode it.
const HEADER_PROBE_BYTES: usize = 256 * 1024;

/// A small file that already fits its bucket is not worth re-encoding.
const KEEP_ORIGINAL_BELOW: u64 = 200 * 1024;

const JPEG_QUALITY: u8 = 72;

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
}

impl Media {
    /// Starts deriving the previews of a stored upload when it is a still picture they apply to.
    pub fn prewarm_preview(&self, hex: &str, content_type: &str) {
        if matches!(content_type, "image/jpeg" | "image/png" | "image/webp") {
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
    pub(super) fn new(dir: PathBuf) -> Self {
        Self {
            dir,
            gate: Arc::new(Semaphore::new(1)),
            prewarming: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn path(&self, hex: &str, bucket: u32) -> PathBuf {
        self.dir.join(format!("{hex}.{bucket}"))
    }

    /// Resolves the preview of `original` at `bucket`, generating it on first use.
    ///
    /// An empty derived file records that the original is the answer, so a
    /// picture that cannot or need not shrink is judged once, not per request.
    pub async fn resolve(&self, hex: &str, original: &Path, bucket: u32) -> io::Result<Preview> {
        self.resolve_with(hex, original, bucket, derive_one).await
    }

    /// The permit moves into the blocking task, so a cancelled request cannot free the gate
    /// while its decode is still running.
    async fn resolve_with<F>(
        &self,
        hex: &str,
        original: &Path,
        bucket: u32,
        derive: F,
    ) -> io::Result<Preview>
    where
        F: FnOnce(&Path, u32) -> io::Result<Option<Vec<u8>>> + Send + 'static,
    {
        let path = self.path(hex, bucket);
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
        let original = original.to_path_buf();
        let target = path.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
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
        let mut missing = Vec::new();
        for bucket in BUCKETS {
            if existing(&self.path(hex, bucket)).await?.is_none() {
                missing.push(bucket);
            }
        }
        if missing.is_empty() {
            return Ok(());
        }
        let original = original.to_path_buf();
        let targets: Vec<(u32, PathBuf)> = missing
            .into_iter()
            .map(|bucket| (bucket, self.path(hex, bucket)))
            .collect();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let buckets: Vec<u32> = targets.iter().map(|(bucket, _)| *bucket).collect();
            let derived = derive_many(&original, &buckets)?;
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

/// The preview bytes at one `bucket`, or `None` when the original should be served.
fn derive_one(original: &Path, bucket: u32) -> io::Result<Option<Vec<u8>>> {
    Ok(derive_many(original, &[bucket])?.pop().flatten())
}

/// The preview bytes at each of `buckets`, from one decode of `original`.
///
/// `None` entries mean the original should be served. A picture this cannot decode is `None`
/// too rather than an error: the original is always a correct answer, and the same picture
/// would fail again.
fn derive_many(original: &Path, buckets: &[u32]) -> io::Result<Vec<Option<Vec<u8>>>> {
    let none = || Ok(vec![None; buckets.len()]);
    let len = std::fs::metadata(original)?.len();
    if len > MAX_SOURCE_BYTES {
        return none();
    }
    let bytes = std::fs::read(original)?;
    let probe = &bytes[..bytes.len().min(HEADER_PROBE_BYTES)];
    let Some(header) = inspect(probe) else {
        return none();
    };
    let decodable = matches!(
        header.content_type,
        "image/jpeg" | "image/png" | "image/webp"
    );
    let pixels = u64::from(header.width) * u64::from(header.height);
    if !decodable || header.animated || pixels > MAX_SOURCE_PIXELS {
        return none();
    }
    let longest = header.width.max(header.height);
    let wanted = |bucket: u32| longest > bucket || len >= KEEP_ORIGINAL_BELOW;
    if !buckets.iter().any(|bucket| wanted(*bucket)) {
        return none();
    }
    let Some((full, orientation)) = decode(&bytes) else {
        return none();
    };
    drop(bytes);
    Ok(render_buckets(
        &full,
        orientation,
        header.content_type,
        buckets,
        len,
        wanted,
    ))
}

/// Encodes `full` at each bucket, largest first so every smaller one shrinks the last result, not the whole raster.
fn render_buckets(
    full: &DynamicImage,
    orientation: Orientation,
    content_type: &str,
    buckets: &[u32],
    original_len: u64,
    wanted: impl Fn(u32) -> bool,
) -> Vec<Option<Vec<u8>>> {
    let mut derived = vec![None; buckets.len()];
    let mut order: Vec<usize> = (0..buckets.len()).collect();
    order.sort_by_key(|index| std::cmp::Reverse(buckets[*index]));
    let mut previous: Option<DynamicImage> = None;
    for index in order {
        if !wanted(buckets[index]) {
            continue;
        }
        let fitted = fit(previous.as_ref().unwrap_or(full), buckets[index]);
        let mut upright = fitted.clone();
        upright.apply_orientation(orientation);
        derived[index] = encode(&upright, content_type == "image/png")
            .filter(|encoded| encoded.len() as u64 * 10 < original_len * 9);
        previous = Some(fitted);
    }
    derived
}

fn decode(bytes: &[u8]) -> Option<(DynamicImage, Orientation)> {
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .ok()?;
    let mut limits = Limits::default();
    limits.max_alloc = Some(DECODE_ALLOC_LIMIT);
    reader.limits(limits);
    let mut decoder = reader.into_decoder().ok()?;
    let orientation = decoder.orientation().unwrap_or(Orientation::NoTransforms);
    let full = DynamicImage::from_decoder(decoder).ok()?;
    Some((full, orientation))
}

/// Photographs go to JPEG; a picture with real transparency, or a PNG that
/// might be flat graphics, is also tried as lossless WebP and the smaller wins.
fn encode(img: &DynamicImage, try_lossless: bool) -> Option<Vec<u8>> {
    let rgba = img.to_rgba8();
    let transparent = rgba.pixels().any(|p| p.0[3] < 255);
    let jpeg = (!transparent).then(|| {
        let mut out = Vec::new();
        let rgb = img.to_rgb8();
        JpegEncoder::new_with_quality(&mut out, JPEG_QUALITY)
            .encode(
                rgb.as_raw(),
                rgb.width(),
                rgb.height(),
                ExtendedColorType::Rgb8,
            )
            .ok()
            .map(|()| out)
    });
    let jpeg = jpeg.flatten();
    let webp = (transparent || try_lossless).then(|| {
        let mut out = Vec::new();
        WebPEncoder::new_lossless(&mut out)
            .encode(
                rgba.as_raw(),
                rgba.width(),
                rgba.height(),
                ExtendedColorType::Rgba8,
            )
            .ok()
            .map(|()| out)
    });
    let webp = webp.flatten();
    match (jpeg, webp) {
        (Some(j), Some(w)) => Some(if w.len() < j.len() { w } else { j }),
        (j, w) => j.or(w),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::Media;

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
        );
        std::fs::create_dir_all(&previews.dir).unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();

        let first = previews.clone();
        let request = tokio::spawn(async move {
            first
                .resolve_with("aa", Path::new("x"), 320, move |_, _| {
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
            .resolve(&hex, &media.attachment_file(&hex), 640)
            .await
            .unwrap();
        assert!(matches!(resolved, Preview::Derived(_)));
        assert_eq!(media.previews().files().await.unwrap().len(), 1);

        media.delete_attachment(&hex).await.unwrap();

        assert!(media.previews().files().await.unwrap().is_empty());
    }
}
