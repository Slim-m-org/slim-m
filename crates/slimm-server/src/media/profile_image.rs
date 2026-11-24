// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shrinks an uploaded profile picture to the largest size any client draws it at.

use std::io::Cursor;

use image::codecs::jpeg::JpegEncoder;
use image::{DynamicImage, ImageFormat};

use super::image_header::inspect;
use super::preview_derive::decode;
use super::preview_scale::fit;

/// Longest side an avatar or Space icon is stored at.
pub const AVATAR_SIDE: u32 = 512;

/// Longest side a profile or Space banner is stored at.
pub const BANNER_SIDE: u32 = 1280;

const JPEG_QUALITY: u8 = 88;

/// `bytes` fitted within `max_side`; a picture already that small, a moving one, or one that
/// cannot be re-encoded is returned as it came.
pub async fn fit_profile_image(bytes: Vec<u8>, max_side: u32) -> Vec<u8> {
    tokio::task::spawn_blocking(move || shrink(bytes, max_side))
        .await
        .unwrap_or_default()
}

fn shrink(bytes: Vec<u8>, max_side: u32) -> Vec<u8> {
    let Some(header) = inspect(&bytes) else {
        return bytes;
    };
    if header.animated || header.width.max(header.height) <= max_side {
        return bytes;
    }
    let jpeg = header.content_type == "image/jpeg";
    let Some((full, orientation)) = decode(&bytes) else {
        return bytes;
    };
    let mut fitted = fit(&full, max_side);
    fitted.apply_orientation(orientation);
    encode(&fitted, jpeg).unwrap_or(bytes)
}

fn encode(img: &DynamicImage, jpeg: bool) -> Option<Vec<u8>> {
    let mut out = Cursor::new(Vec::new());
    if jpeg {
        let rgb = img.to_rgb8();
        JpegEncoder::new_with_quality(&mut out, JPEG_QUALITY)
            .encode_image(&rgb)
            .ok()?;
    } else {
        img.write_to(&mut out, ImageFormat::Png).ok()?;
    }
    Some(out.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Rgb};

    fn png(side: u32) -> Vec<u8> {
        let img = ImageBuffer::from_pixel(side, side, Rgb([10u8, 120, 200]));
        let mut out = Cursor::new(Vec::new());
        DynamicImage::ImageRgb8(img)
            .write_to(&mut out, ImageFormat::Png)
            .unwrap();
        out.into_inner()
    }

    #[test]
    fn a_large_picture_is_stored_at_the_target_size() {
        let shrunk = shrink(png(2000), AVATAR_SIDE);
        let header = inspect(&shrunk).expect("still a picture");
        assert_eq!((header.width, header.height), (AVATAR_SIDE, AVATAR_SIDE));
    }

    #[test]
    fn a_small_picture_is_left_alone() {
        let small = png(300);
        assert_eq!(shrink(small.clone(), AVATAR_SIDE), small);
    }

    #[test]
    fn bytes_that_are_not_a_picture_are_left_alone() {
        assert_eq!(shrink(b"nope".to_vec(), AVATAR_SIDE), b"nope");
    }
}
