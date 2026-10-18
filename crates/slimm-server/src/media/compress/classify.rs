// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Telling a screenshot or drawing from a photograph, because only a photograph
//! may be re-encoded lossily.

use image::DynamicImage;

/// Share of pixels equal to their left neighbour above which a picture is a graphic.
const GRAPHIC_FLAT_SHARE: f64 = 0.6;
/// Distinct colours below which a picture is a graphic, whatever its layout.
const GRAPHIC_COLORS: u32 = 2048;

/// Whether the picture looks drawn (text, UI, flat fills) and so must stay
/// lossless. A photograph has sensor noise or lens blur, so few neighbours match
/// exactly and it spends many colours; a screenshot is the reverse. Even a
/// denoised phone photo of a plain wall stays under the flat-share line.
pub fn is_graphic(image: &DynamicImage) -> bool {
    let rgb = image.to_rgb8();
    let width = rgb.width() as usize;
    if width < 2 {
        return true;
    }
    let mut seen = vec![0u64; 1 << 18];
    let (mut flat, mut total, mut colors) = (0u64, 0u64, 0u32);
    for row in rgb.as_raw().chunks_exact(width * 3) {
        let mut previous: Option<&[u8]> = None;
        for px in row.chunks_exact(3) {
            let key = (usize::from(px[0]) << 16) | (usize::from(px[1]) << 8) | usize::from(px[2]);
            let (word, bit) = (key >> 6, 1u64 << (key & 63));
            if seen[word] & bit == 0 {
                seen[word] |= bit;
                colors += 1;
            }
            if previous == Some(px) {
                flat += 1;
            }
            previous = Some(px);
            total += 1;
        }
    }
    total > 0 && (flat as f64 / total as f64 > GRAPHIC_FLAT_SHARE || colors < GRAPHIC_COLORS)
}
