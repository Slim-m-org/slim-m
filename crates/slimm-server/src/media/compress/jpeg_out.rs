// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shrinking a photograph and writing it as a JPEG every client can draw.

use fast_image_resize::images::Image;
use fast_image_resize::{FilterType, PixelType, ResizeAlg, ResizeOptions, Resizer};
use image::DynamicImage;
use jpeg_encoder::{ColorType, Encoder, QuantizationTableType, SamplingFactor};

use super::Metadata;
use super::decode::{Decoded, apply_orientation};
use super::exif::{self, Rewrite};
use super::jpeg_segments::push_app1;

/// How a photograph is written. The numbers come from the measurements in
/// `docs/research/media-compression.md`.
#[derive(Debug, Clone, Copy)]
pub struct Settings {
    pub quality: u8,
    /// The longest side of the result; a smaller picture keeps its size.
    pub long_edge: u32,
    pub sampling: SamplingFactor,
    pub tables: TableKind,
}

#[derive(Debug, Clone, Copy)]
pub enum TableKind {
    Standard,
    MsSsim,
    PsnrHvs,
    ImageMagick,
}

pub const DEFAULT: Settings = Settings {
    quality: 90,
    long_edge: 4096,
    sampling: SamplingFactor::F_2_2,
    tables: TableKind::MsSsim,
};

const XMP_ID: &[u8] = b"http://ns.adobe.com/xap/1.0/\0";
const MAX_APP_SEGMENT: usize = 65_000;

/// The photograph as a JPEG, upright and at most `settings.long_edge` on a side.
pub fn encode(decoded: Decoded, metadata: Metadata, settings: &Settings) -> Option<Vec<u8>> {
    let Decoded {
        image,
        icc,
        exif: source_exif,
        xmp,
        orientation,
    } = decoded;
    let mut upright = shrink(image, settings.long_edge)?;
    apply_orientation(&mut upright, orientation);
    let (width, height) = (upright.width(), upright.height());
    let gray = upright.color().channel_count() <= 2;
    let (pixels, color) = if gray {
        (upright.into_luma8().into_raw(), ColorType::Luma)
    } else {
        (upright.into_rgb8().into_raw(), ColorType::Rgb)
    };

    let mut out = Vec::with_capacity(pixels.len() / 8);
    let mut encoder = Encoder::new(&mut out, settings.quality);
    encoder.set_sampling_factor(settings.sampling);
    encoder.set_progressive(true);
    encoder.set_optimized_huffman_tables(true);
    encoder.set_quantization_tables(tables(settings.tables), tables(settings.tables));
    if let Some(icc) = icc.as_deref().filter(|p| p.len() < 16 * MAX_APP_SEGMENT) {
        encoder.add_icc_profile(icc).ok()?;
    }
    for (segment, data) in metadata_segments(
        source_exif.as_deref(),
        xmp.as_deref(),
        metadata,
        (width, height),
    ) {
        encoder.add_app_segment(segment, data).ok()?;
    }
    let (w16, h16) = (u16::try_from(width).ok()?, u16::try_from(height).ok()?);
    encoder.encode(&pixels, w16, h16, color).ok()?;
    Some(out)
}

fn tables(kind: TableKind) -> QuantizationTableType {
    match kind {
        TableKind::Standard => QuantizationTableType::Default,
        TableKind::MsSsim => QuantizationTableType::CustomMsSsim,
        TableKind::PsnrHvs => QuantizationTableType::CustomPsnrHvs,
        TableKind::ImageMagick => QuantizationTableType::ImageMagick,
    }
}

/// The APP1 blocks the policy lets through, already describing the upright, resized pixels.
fn metadata_segments(
    exif_block: Option<&[u8]>,
    xmp: Option<&[u8]>,
    metadata: Metadata,
    dimensions: (u32, u32),
) -> Vec<(u8, Vec<u8>)> {
    let rewrite = Rewrite {
        orientation: Some(1),
        dimensions: Some(dimensions),
    };
    let tiff = match (metadata, exif_block) {
        (Metadata::Keep, Some(block)) => Some(exif::patched(block, rewrite)),
        (Metadata::RemoveLocation, Some(block)) => exif::without_location(block, rewrite),
        _ => None,
    };
    let mut out = Vec::new();
    if let Some(tiff) = tiff.filter(|t| t.len() + 6 <= MAX_APP_SEGMENT) {
        let mut segment = Vec::new();
        push_app1(&mut segment, &tiff);
        out.push((1, segment[4..].to_vec()));
    }
    if metadata == Metadata::Keep
        && let Some(xmp) = xmp.filter(|x| x.len() + XMP_ID.len() <= MAX_APP_SEGMENT)
    {
        out.push((1, [XMP_ID, xmp].concat()));
    }
    out
}

/// The picture scaled down so its longest side is at most `long_edge`.
fn shrink(image: DynamicImage, long_edge: u32) -> Option<DynamicImage> {
    let (w, h) = (image.width(), image.height());
    if w.max(h) <= long_edge {
        return Some(image);
    }
    let scale = f64::from(long_edge) / f64::from(w.max(h));
    let nw = ((f64::from(w) * scale).round() as u32).max(1);
    let nh = ((f64::from(h) * scale).round() as u32).max(1);
    let gray = image.color().channel_count() <= 2;
    let (pixels, kind) = if gray {
        (image.into_luma8().into_raw(), PixelType::U8)
    } else {
        (image.into_rgb8().into_raw(), PixelType::U8x3)
    };
    let source = Image::from_vec_u8(w, h, pixels, kind).ok()?;
    let mut target = Image::new(nw, nh, kind);
    let options = ResizeOptions::new().resize_alg(ResizeAlg::Convolution(FilterType::Lanczos3));
    Resizer::new().resize(&source, &mut target, &options).ok()?;
    let raw = target.into_vec();
    Some(if gray {
        DynamicImage::ImageLuma8(image::GrayImage::from_raw(nw, nh, raw)?)
    } else {
        DynamicImage::ImageRgb8(image::RgbImage::from_raw(nw, nh, raw)?)
    })
}
