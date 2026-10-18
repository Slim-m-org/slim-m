// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Decoding a photo to pixels, with the colour profile and metadata it carried.

use std::io::Cursor;

use image::metadata::Orientation;
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, Limits};

use super::Candidate;
use super::exif;
use super::jpeg_segments;
use super::sniff::Kind;

/// Bytes a decoder may allocate for one picture.
const DECODE_ALLOC_LIMIT: u64 = 1 << 30;

pub struct Decoded {
    pub image: DynamicImage,
    pub icc: Option<Vec<u8>>,
    pub exif: Option<Vec<u8>>,
    pub xmp: Option<Vec<u8>>,
    /// The EXIF orientation still to apply to `image`, 1 when the pixels are upright.
    pub orientation: u16,
}

impl Decoded {
    /// Whether any pixel is not fully opaque.
    pub fn has_transparency(&self) -> bool {
        match &self.image {
            DynamicImage::ImageRgba8(img) => img.pixels().any(|p| p.0[3] != u8::MAX),
            DynamicImage::ImageLumaA8(img) => img.pixels().any(|p| p.0[1] != u8::MAX),
            DynamicImage::ImageRgba16(img) => img.pixels().any(|p| p.0[3] != u16::MAX),
            DynamicImage::ImageLumaA16(img) => img.pixels().any(|p| p.0[1] != u16::MAX),
            DynamicImage::ImageRgba32F(_) => true,
            _ => false,
        }
    }
}

/// The DCT reduction (1, 2, 4 or 8) that still leaves a JPEG at least `long_edge` on its long side.
pub fn jpeg_scale_divisor(width: u32, height: u32, long_edge: u32) -> u64 {
    let edge = width.max(height);
    [8u32, 4, 2]
        .into_iter()
        .find(|d| edge / d >= long_edge)
        .map_or(1, u64::from)
}

/// Decodes `candidate`'s bytes. A JPEG much larger than `long_edge` is decoded
/// at a reduced DCT scale, so its full-size pixels never exist in memory; when
/// that decoder cannot take the file the whole job is refused, not retried at full size.
pub fn decode(candidate: Candidate, bytes: &[u8], long_edge: u32) -> Option<Decoded> {
    match candidate.kind {
        Kind::Heic => decode_heic(bytes),
        Kind::Jpeg if jpeg_scale_divisor(candidate.width, candidate.height, long_edge) > 1 => {
            decode_jpeg_scaled(candidate, bytes, long_edge)
        }
        kind => decode_with_image(kind, bytes),
    }
}

fn decode_jpeg_scaled(candidate: Candidate, bytes: &[u8], long_edge: u32) -> Option<Decoded> {
    let edge = f64::from(candidate.width.max(candidate.height));
    let scale = f64::from(long_edge) / edge;
    let want_w = (f64::from(candidate.width) * scale).ceil() as u16;
    let want_h = (f64::from(candidate.height) * scale).ceil() as u16;
    let mut decoder = jpeg_decoder::Decoder::new(Cursor::new(bytes));
    decoder.read_info().ok()?;
    let (w, h) = decoder.scale(want_w, want_h).ok()?;
    let pixels = decoder.decode().ok()?;
    let format = decoder.info()?.pixel_format;
    let image = match format {
        jpeg_decoder::PixelFormat::RGB24 => DynamicImage::ImageRgb8(image::RgbImage::from_raw(
            u32::from(w),
            u32::from(h),
            pixels,
        )?),
        jpeg_decoder::PixelFormat::L8 => DynamicImage::ImageLuma8(image::GrayImage::from_raw(
            u32::from(w),
            u32::from(h),
            pixels,
        )?),
        _ => return None,
    };
    let exif = jpeg_segments::exif_of(bytes);
    let orientation = exif.as_deref().and_then(exif::orientation).unwrap_or(1);
    Some(Decoded {
        image,
        icc: decoder.icc_profile(),
        exif,
        xmp: jpeg_segments::xmp_of(bytes),
        orientation,
    })
}

fn decode_with_image(kind: Kind, bytes: &[u8]) -> Option<Decoded> {
    let format = match kind {
        Kind::Jpeg => ImageFormat::Jpeg,
        Kind::Png => ImageFormat::Png,
        Kind::Webp => ImageFormat::WebP,
        Kind::Bmp => ImageFormat::Bmp,
        Kind::Tiff => ImageFormat::Tiff,
        Kind::Heic => return None,
    };
    let mut decoder = ImageReader::with_format(Cursor::new(bytes), format)
        .into_decoder()
        .ok()?;
    let mut limits = Limits::default();
    limits.max_alloc = Some(DECODE_ALLOC_LIMIT);
    decoder.set_limits(limits).ok()?;
    let icc = decoder.icc_profile().ok().flatten();
    let exif = decoder.exif_metadata().ok().flatten().or_else(|| {
        (kind == Kind::Jpeg)
            .then(|| jpeg_segments::exif_of(bytes))
            .flatten()
    });
    let xmp = (kind == Kind::Jpeg)
        .then(|| jpeg_segments::xmp_of(bytes))
        .flatten();
    let orientation = exif.as_deref().and_then(exif::orientation).unwrap_or(1);
    let image = DynamicImage::from_decoder(decoder).ok()?;
    Some(Decoded {
        image,
        icc,
        exif,
        xmp,
        orientation,
    })
}

fn decode_heic(bytes: &[u8]) -> Option<Decoded> {
    use zune_heic::HeifDecoder;
    use zune_heic::zune_core::bytestream::ZCursor;
    use zune_heic::zune_core::colorspace::ColorSpace;

    let mut decoder = HeifDecoder::new(ZCursor::new(bytes));
    decoder.decode_headers().ok()?;
    let (w, h) = (decoder.width()? as u32, decoder.height()? as u32);
    let space = decoder.colorspace()?;
    let pixels = decoder.decode().ok()?;
    let image = match space {
        ColorSpace::RGB => DynamicImage::ImageRgb8(image::RgbImage::from_raw(w, h, pixels)?),
        ColorSpace::RGBA => DynamicImage::ImageRgba8(image::RgbaImage::from_raw(w, h, pixels)?),
        ColorSpace::Luma => DynamicImage::ImageLuma8(image::GrayImage::from_raw(w, h, pixels)?),
        _ => return None,
    };
    Some(Decoded {
        image,
        icc: decoder.icc_data().cloned(),
        exif: decoder.exif_data().cloned(),
        xmp: None,
        // The decoder applies the file's own rotation and mirroring.
        orientation: 1,
    })
}

/// Turns the pixels upright, in place.
pub fn apply_orientation(image: &mut DynamicImage, orientation: u16) {
    if let Some(o) = u8::try_from(orientation)
        .ok()
        .and_then(Orientation::from_exif)
    {
        image.apply_orientation(o);
    }
}
