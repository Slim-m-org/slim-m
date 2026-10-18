// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Lossless PNG: smaller bytes, identical pixels.

use std::io::Cursor;

use image::codecs::png::PngEncoder;
use image::{DynamicImage, ImageEncoder};

use super::Metadata;

/// oxipng's preset 2: most of the saving of the slow presets at a fraction of the time.
const PRESET: u8 = 2;

/// `png` re-optimised without changing a pixel. Colour chunks stay; with the
/// policy asking for metadata to go, text and EXIF chunks go too.
pub fn optimize(png: &[u8], metadata: Metadata) -> Option<Vec<u8>> {
    let mut options = oxipng::Options::from_preset(PRESET);
    options.strip = match metadata {
        Metadata::Keep => oxipng::StripChunks::None,
        _ => oxipng::StripChunks::Safe,
    };
    options.fix_errors = false;
    oxipng::optimize_from_memory(png, &options).ok()
}

/// Pixels written as a PNG then optimised, for sources that are not one already.
pub fn encode(image: &DynamicImage, icc: Option<&[u8]>, metadata: Metadata) -> Option<Vec<u8>> {
    let rgba = image.color().has_alpha();
    let mut raw = Vec::new();
    let mut encoder = PngEncoder::new(Cursor::new(&mut raw));
    if let Some(icc) = icc {
        encoder.set_icc_profile(icc.to_vec()).ok()?;
    }
    if rgba {
        let img = image.to_rgba8();
        encoder
            .write_image(
                img.as_raw(),
                img.width(),
                img.height(),
                image::ExtendedColorType::Rgba8,
            )
            .ok()?;
    } else {
        let img = image.to_rgb8();
        encoder
            .write_image(
                img.as_raw(),
                img.width(),
                img.height(),
                image::ExtendedColorType::Rgb8,
            )
            .ok()?;
    }
    optimize(&raw, metadata)
}
