// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Decoding a photo to pixels, with the colour profile and metadata it carried.

use std::io::Cursor;

use image::metadata::Orientation;
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, Limits};

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

pub fn decode(kind: Kind, bytes: &[u8]) -> Option<Decoded> {
    match kind {
        Kind::Heic => decode_heic(bytes),
        _ => decode_with_image(kind, bytes),
    }
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
