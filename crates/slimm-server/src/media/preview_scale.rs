// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shrinks a decoded photo with a whole-pixel box average before the exact resize.
//!
//! `DynamicImage::resize` converts to floats and runs two passes over the full
//! raster, which cost more than decoding a 24 megapixel photo. Averaging k by k
//! blocks first leaves the exact filter a raster under twice its target size.

use image::{DynamicImage, GrayAlphaImage, GrayImage, RgbImage, RgbaImage, imageops};

/// `img` fitted within `bucket` on the longest side, keeping its aspect ratio.
pub(super) fn fit(img: &DynamicImage, bucket: u32) -> DynamicImage {
    let longest = img.width().max(img.height());
    let factor = (longest / bucket) as usize;
    let reduced = if factor < 2 {
        None
    } else {
        Some(prefilter(img, factor))
    };
    let source = reduced.as_ref().unwrap_or(img);
    if source.width().max(source.height()) > bucket {
        source.resize(bucket, bucket, imageops::FilterType::Triangle)
    } else {
        source.clone()
    }
}

fn prefilter(img: &DynamicImage, factor: usize) -> DynamicImage {
    let (width, height) = (img.width() as usize, img.height() as usize);
    let dims = ((width / factor) as u32, (height / factor) as u32);
    match img {
        DynamicImage::ImageRgb8(raw) => {
            let out = box_average(raw.as_raw(), width, height, 3, factor);
            RgbImage::from_raw(dims.0, dims.1, out).map(DynamicImage::ImageRgb8)
        }
        DynamicImage::ImageRgba8(raw) => {
            let out = box_average(raw.as_raw(), width, height, 4, factor);
            RgbaImage::from_raw(dims.0, dims.1, out).map(DynamicImage::ImageRgba8)
        }
        DynamicImage::ImageLuma8(raw) => {
            let out = box_average(raw.as_raw(), width, height, 1, factor);
            GrayImage::from_raw(dims.0, dims.1, out).map(DynamicImage::ImageLuma8)
        }
        DynamicImage::ImageLumaA8(raw) => {
            let out = box_average(raw.as_raw(), width, height, 2, factor);
            GrayAlphaImage::from_raw(dims.0, dims.1, out).map(DynamicImage::ImageLumaA8)
        }
        other => {
            let rgba = other.to_rgba8();
            let out = box_average(rgba.as_raw(), width, height, 4, factor);
            RgbaImage::from_raw(dims.0, dims.1, out).map(DynamicImage::ImageRgba8)
        }
    }
    .expect("a box average yields exactly width * height * channels bytes")
}

/// The mean of every `factor` by `factor` block; the right and bottom remainder is dropped.
fn box_average(src: &[u8], width: usize, height: usize, channels: usize, factor: usize) -> Vec<u8> {
    let (out_w, out_h) = (width / factor, height / factor);
    let mut out = Vec::with_capacity(out_w * out_h * channels);
    let mut sums = vec![0u32; out_w * channels];
    let area = (factor * factor) as u32;
    let stride = width * channels;
    for block_row in 0..out_h {
        sums.fill(0);
        let first = block_row * factor * stride;
        for row in src[first..first + factor * stride].chunks_exact(stride) {
            let covered = &row[..out_w * factor * channels];
            for (sum, block) in sums
                .chunks_exact_mut(channels)
                .zip(covered.chunks_exact(factor * channels))
            {
                for pixel in block.chunks_exact(channels) {
                    for (total, value) in sum.iter_mut().zip(pixel) {
                        *total += u32::from(*value);
                    }
                }
            }
        }
        out.extend(sums.iter().map(|total| ((total + area / 2) / area) as u8));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_block_is_replaced_by_its_mean() {
        let src = [0u8, 100, 200, 100, 100, 100, 200, 100, 0];
        assert_eq!(box_average(&src, 3, 3, 1, 3), vec![100]);
    }

    #[test]
    fn the_remainder_beyond_whole_blocks_is_dropped() {
        let src: Vec<u8> = (0..5 * 5 * 3).map(|n| (n % 251) as u8).collect();
        let out = box_average(&src, 5, 5, 3, 2);
        assert_eq!(out.len(), 2 * 2 * 3);
    }

    #[test]
    fn a_large_photo_lands_on_the_bucket_with_its_aspect_ratio() {
        let img = DynamicImage::ImageRgb8(RgbImage::new(6000, 4000));
        let fitted = fit(&img, 320);
        assert_eq!((fitted.width(), fitted.height()), (320, 213));
    }

    #[test]
    fn a_picture_already_inside_the_bucket_is_untouched() {
        let img = DynamicImage::ImageRgb8(RgbImage::new(300, 200));
        let fitted = fit(&img, 320);
        assert_eq!((fitted.width(), fitted.height()), (300, 200));
    }
}
