// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Decoding a stored picture and encoding its previews and first-frame stills.

use std::io::{self, Cursor};
use std::path::Path;

use image::codecs::jpeg::JpegEncoder;
use image::codecs::webp::WebPEncoder;
use image::metadata::Orientation;
use image::{DynamicImage, ExtendedColorType, ImageDecoder, ImageReader, Limits};

use super::compress::{decode_reduced_jpeg, jpeg_scale_divisor};
use super::image_header::{ImageHeader, gif_canvas, inspect, jpeg_is_progressive};
use super::preview::BUCKETS;
use super::preview_scale::fit;

/// Pictures with more pixels are served as the original instead of decoded in full.
const MAX_SOURCE_PIXELS: u64 = 40_000_000;

/// A baseline JPEG up to this many pixels is decoded at a reduced scale instead.
const MAX_REDUCED_PIXELS: u64 = 160_000_000;

/// Files larger than this are served as the original instead of read into memory.
const MAX_SOURCE_BYTES: u64 = 48 * 1024 * 1024;

/// The decoder's allocation ceiling: an RGB raster at [`MAX_SOURCE_PIXELS`] plus working room.
const DECODE_ALLOC_LIMIT: u64 = 192 * 1024 * 1024;

/// How much of the file is read to learn its dimensions before deciding to decode it.
const HEADER_PROBE_BYTES: usize = 256 * 1024;

/// A small file that already fits its bucket is not worth re-encoding.
const KEEP_ORIGINAL_BELOW: u64 = 200 * 1024;

const JPEG_QUALITY: u8 = 72;

/// The decoded raster plus the resized copies one preview decode keeps.
const PREVIEW_BYTES_PER_PIXEL: u64 = 4;
const PREVIEW_FIXED_BYTES: u64 = 16 * 1024 * 1024;

/// A reduced JPEG decode holds planes and a converted copy at the reduced size.
const REDUCED_BYTES_PER_PIXEL: u64 = 12;

/// What is derived from a stored picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Variant {
    /// A smaller copy of a still picture.
    Preview,
    /// The first frame of a picture that animates.
    Still,
}

impl Variant {
    pub(super) const ALL: [Variant; 2] = [Self::Preview, Self::Still];

    /// The part of a preview file name that tells the variants apart.
    pub(super) fn tag(self) -> &'static str {
        match self {
            Self::Preview => "",
            Self::Still => "still.",
        }
    }
}

/// How one stored picture will be decoded.
pub(super) struct Plan {
    header: ImageHeader,
    len: u64,
    divisor: u32,
}

impl Plan {
    /// The peak memory of decoding: the file, its raster and some working room.
    fn estimate(&self) -> u64 {
        let pixels = u64::from(self.header.width) * u64::from(self.header.height);
        let divisor = u64::from(self.divisor);
        let raster = if self.divisor > 1 {
            pixels / (divisor * divisor) * REDUCED_BYTES_PER_PIXEL
        } else {
            pixels * PREVIEW_BYTES_PER_PIXEL
        };
        self.len + raster + PREVIEW_FIXED_BYTES
    }
}

fn header_of(probe: &[u8]) -> Option<ImageHeader> {
    inspect(probe).or_else(|| gif_canvas(probe))
}

/// Whether `header` is a picture whose first frame is a better preview than the whole file.
fn animates(header: &ImageHeader) -> bool {
    header.content_type == "image/gif" || header.animated
}

/// How `probe`, the start of a `len` byte file, is to be decoded for `variant`; `None` when the
/// original is the answer.
pub(super) fn plan(variant: Variant, probe: &[u8], len: u64) -> Option<Plan> {
    if len > MAX_SOURCE_BYTES {
        return None;
    }
    let header = header_of(probe)?;
    let pixels = u64::from(header.width) * u64::from(header.height);
    let jpeg = header.content_type == "image/jpeg";
    let divisor = match variant {
        Variant::Preview if header.animated || header.content_type == "image/gif" => return None,
        Variant::Preview if pixels <= MAX_SOURCE_PIXELS => 1,
        Variant::Preview if jpeg && pixels <= MAX_REDUCED_PIXELS && !jpeg_is_progressive(probe) => {
            let largest = BUCKETS[BUCKETS.len() - 1];
            match jpeg_scale_divisor(header.width, header.height, largest) {
                1 => return None,
                divisor => u32::try_from(divisor).ok()?,
            }
        }
        Variant::Still if animates(&header) && !jpeg && pixels <= MAX_SOURCE_PIXELS => 1,
        _ => return None,
    };
    Some(Plan {
        header,
        len,
        divisor,
    })
}

/// The start of `original`, as much as is needed to plan its decode, and its length.
async fn read_probe(original: &Path) -> Option<(Vec<u8>, u64)> {
    use tokio::io::AsyncReadExt;
    let mut file = tokio::fs::File::open(original).await.ok()?;
    let len = file.metadata().await.ok()?.len();
    let mut probe = vec![0u8; HEADER_PROBE_BYTES.min(usize::try_from(len).ok()?)];
    file.read_exact(&mut probe).await.ok()?;
    Some((probe, len))
}

/// The peak memory of deriving `variant` from `original`. `None` when the file would not be
/// decoded, so needs no reservation.
pub(super) async fn decode_estimate(original: &Path, variant: Variant) -> Option<u64> {
    let (probe, len) = read_probe(original).await?;
    plan(variant, &probe, len).map(|plan| plan.estimate())
}

/// [`Variant::Still`] for a picture that animates, [`Variant::Preview`] for any other.
pub(super) async fn variant_of(original: &Path) -> Variant {
    let animated = read_probe(original)
        .await
        .and_then(|(probe, _)| header_of(&probe))
        .is_some_and(|header| animates(&header));
    if animated {
        Variant::Still
    } else {
        Variant::Preview
    }
}

/// The preview bytes at one `bucket`, or `None` when the original should be served.
pub(super) fn derive_one(
    original: &Path,
    variant: Variant,
    bucket: u32,
) -> io::Result<Option<Vec<u8>>> {
    Ok(derive_many(original, variant, &[bucket])?.pop().flatten())
}

/// The preview bytes at each of `buckets`, from one decode of `original`.
///
/// `None` entries mean the original should be served. A picture this cannot decode is `None`
/// too rather than an error: the original is always a correct answer, and the same picture
/// would fail again.
pub(super) fn derive_many(
    original: &Path,
    variant: Variant,
    buckets: &[u32],
) -> io::Result<Vec<Option<Vec<u8>>>> {
    let none = || Ok(vec![None; buckets.len()]);
    let len = std::fs::metadata(original)?.len();
    if len > MAX_SOURCE_BYTES {
        return none();
    }
    let bytes = std::fs::read(original)?;
    let probe = &bytes[..bytes.len().min(HEADER_PROBE_BYTES)];
    let Some(plan) = plan(variant, probe, len) else {
        return none();
    };
    let header = plan.header;
    let longest = header.width.max(header.height);
    let wanted =
        |bucket: u32| variant == Variant::Still || longest > bucket || len >= KEEP_ORIGINAL_BELOW;
    if !buckets.iter().any(|bucket| wanted(*bucket)) {
        return none();
    }
    let decoded = if plan.divisor > 1 {
        reduced(&bytes, &header)
    } else {
        decode(&bytes)
    };
    drop(bytes);
    let Some((full, orientation)) = decoded else {
        return none();
    };
    let accept = |encoded: u64| match variant {
        Variant::Preview => encoded * 10 < len * 9,
        Variant::Still => encoded < len,
    };
    let lossless = variant == Variant::Still || header.content_type == "image/png";
    Ok(render_buckets(
        &full,
        orientation,
        buckets,
        lossless,
        wanted,
        accept,
    ))
}

/// Encodes `full` at each bucket, largest first so every smaller one shrinks the last result, not the whole raster.
fn render_buckets(
    full: &DynamicImage,
    orientation: Orientation,
    buckets: &[u32],
    lossless: bool,
    wanted: impl Fn(u32) -> bool,
    accept: impl Fn(u64) -> bool,
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
        derived[index] = encode(&upright, lossless).filter(|encoded| accept(encoded.len() as u64));
        previous = Some(fitted);
    }
    derived
}

fn reduced(bytes: &[u8], header: &ImageHeader) -> Option<(DynamicImage, Orientation)> {
    let largest = BUCKETS[BUCKETS.len() - 1];
    let (image, exif) = decode_reduced_jpeg(bytes, header.width, header.height, largest)?;
    let orientation = u8::try_from(exif)
        .ok()
        .and_then(Orientation::from_exif)
        .unwrap_or(Orientation::NoTransforms);
    Some((image, orientation))
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

    fn jpeg_header(marker: u8, width: u16, height: u16) -> Vec<u8> {
        let mut out = vec![0xFF, 0xD8, 0xFF, marker, 0, 11, 8];
        out.extend_from_slice(&height.to_be_bytes());
        out.extend_from_slice(&width.to_be_bytes());
        out.extend_from_slice(&[1, 1, 0x11, 0]);
        out
    }

    #[test]
    fn a_baseline_photo_past_the_pixel_cap_is_decoded_at_a_reduced_scale() {
        let probe = jpeg_header(0xC0, 12_000, 9_000);

        let planned = plan(Variant::Preview, &probe, 30 << 20).unwrap();

        assert_eq!(planned.divisor, 8);
        assert!(planned.estimate() < 96 << 20, "{}", planned.estimate());
    }

    #[test]
    fn a_progressive_photo_past_the_pixel_cap_is_left_as_the_original() {
        let probe = jpeg_header(0xC2, 12_000, 9_000);

        assert!(plan(Variant::Preview, &probe, 30 << 20).is_none());
    }

    #[test]
    fn a_photo_past_the_reduced_cap_is_left_as_the_original() {
        let probe = jpeg_header(0xC0, 20_000, 10_000);

        assert!(plan(Variant::Preview, &probe, 30 << 20).is_none());
    }

    #[test]
    fn a_still_is_never_planned_for_a_jpeg() {
        let probe = jpeg_header(0xC0, 800, 600);

        assert!(plan(Variant::Still, &probe, 30 << 10).is_none());
    }
}
