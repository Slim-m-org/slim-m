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

use image::codecs::jpeg::JpegEncoder;
use image::codecs::webp::WebPEncoder;
use image::metadata::Orientation;
use image::{DynamicImage, ExtendedColorType, ImageDecoder, ImageReader, Limits, imageops};
use tokio::sync::Semaphore;

use super::image_header::inspect;

/// Longest-side widths a preview may be asked for. Bucketing bounds the files kept per attachment.
pub const BUCKETS: [u32; 3] = [320, 640, 1280];

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
        let path = self.path(hex, bucket);
        if let Some(found) = existing(&path).await? {
            return Ok(found);
        }
        let _permit = self.gate.acquire().await.map_err(io::Error::other)?;
        if let Some(found) = existing(&path).await? {
            return Ok(found);
        }
        let original = original.to_path_buf();
        let target = path.clone();
        tokio::task::spawn_blocking(move || {
            let derived = derive(&original, bucket)?;
            write_atomic(&target, derived.as_deref().unwrap_or_default())?;
            Ok(derived.map_or(Preview::Original, |_| Preview::Derived(target)))
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

/// The preview bytes, or `None` when the original should be served.
///
/// A picture this cannot decode is `None` too rather than an error: the
/// original is always a correct answer, and the same picture would fail again.
fn derive(original: &Path, bucket: u32) -> io::Result<Option<Vec<u8>>> {
    let len = std::fs::metadata(original)?.len();
    if len > MAX_SOURCE_BYTES {
        return Ok(None);
    }
    let bytes = std::fs::read(original)?;
    let probe = &bytes[..bytes.len().min(HEADER_PROBE_BYTES)];
    let Some(header) = inspect(probe) else {
        return Ok(None);
    };
    let decodable = matches!(
        header.content_type,
        "image/jpeg" | "image/png" | "image/webp"
    );
    let pixels = u64::from(header.width) * u64::from(header.height);
    let fits = header.width.max(header.height) <= bucket;
    if !decodable || header.animated || pixels > MAX_SOURCE_PIXELS {
        return Ok(None);
    }
    if fits && len < KEEP_ORIGINAL_BELOW {
        return Ok(None);
    }
    let Some(encoded) = shrink(&bytes, header.content_type, bucket) else {
        return Ok(None);
    };
    Ok((encoded.len() as u64 * 10 < len * 9).then_some(encoded))
}

/// Decodes, fits within `bucket` on the longest side, applies the EXIF
/// orientation and re-encodes without any metadata. Orientation is applied to
/// the small raster, since rotating the full one would double peak memory.
fn shrink(bytes: &[u8], content_type: &str, bucket: u32) -> Option<Vec<u8>> {
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .ok()?;
    let mut limits = Limits::default();
    limits.max_alloc = Some(DECODE_ALLOC_LIMIT);
    reader.limits(limits);
    let mut decoder = reader.into_decoder().ok()?;
    let orientation = decoder.orientation().unwrap_or(Orientation::NoTransforms);
    let full = DynamicImage::from_decoder(decoder).ok()?;
    let mut small = if full.width().max(full.height()) > bucket {
        full.resize(bucket, bucket, imageops::FilterType::Triangle)
    } else {
        full
    };
    small.apply_orientation(orientation);
    encode(&small, content_type == "image/png")
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
