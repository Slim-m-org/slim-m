// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Hand-built headers for each format, since what matters is the bytes the
//! parser walks, not whether a decoder could draw them.

use super::*;

fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut out = (data.len() as u32).to_be_bytes().to_vec();
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    out.extend_from_slice(&[0; 4]);
    out
}

fn png(width: u32, height: u32, animated: bool) -> Vec<u8> {
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = width.to_be_bytes().to_vec();
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
    out.extend(chunk(b"IHDR", &ihdr));
    if animated {
        out.extend(chunk(b"acTL", &[0, 0, 0, 2, 0, 0, 0, 0]));
    }
    out.extend(chunk(b"IDAT", &[0; 8]));
    out.extend(chunk(b"IEND", &[]));
    out
}

fn gif(width: u16, height: u16, frames: usize) -> Vec<u8> {
    let mut out = b"GIF89a".to_vec();
    out.extend_from_slice(&width.to_le_bytes());
    out.extend_from_slice(&height.to_le_bytes());
    out.extend_from_slice(&[0x80, 0, 0]);
    out.extend_from_slice(&[0; 6]);
    out.extend_from_slice(&[0x21, 0xF9, 4, 0, 0, 0, 0, 0]);
    for _ in 0..frames {
        out.push(0x2C);
        out.extend_from_slice(&[0, 0, 0, 0]);
        out.extend_from_slice(&width.to_le_bytes());
        out.extend_from_slice(&height.to_le_bytes());
        out.push(0);
        out.extend_from_slice(&[2, 2, 0x4C, 0x01, 0]);
    }
    out.push(0x3B);
    out
}

fn jpeg(width: u16, height: u16) -> Vec<u8> {
    let mut out = vec![0xFF, 0xD8, 0xFF, 0xE0, 0, 16];
    out.extend_from_slice(b"JFIF\0");
    out.extend_from_slice(&[1, 1, 0, 0, 1, 0, 1, 0, 0]);
    out.extend_from_slice(&[0xFF, 0xC0, 0, 11, 8]);
    out.extend_from_slice(&height.to_be_bytes());
    out.extend_from_slice(&width.to_be_bytes());
    out.extend_from_slice(&[1, 1, 0x11, 0]);
    out.extend_from_slice(&[0xFF, 0xD9]);
    out
}

fn riff(chunk_kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut out = b"RIFF".to_vec();
    out.extend_from_slice(&((data.len() + 12) as u32).to_le_bytes());
    out.extend_from_slice(b"WEBP");
    out.extend_from_slice(chunk_kind);
    out.extend_from_slice(&(data.len() as u32).to_le_bytes());
    out.extend_from_slice(data);
    out
}

fn webp_extended(width: u32, height: u32, animated: bool) -> Vec<u8> {
    let mut data = vec![if animated { 0x02 } else { 0 }, 0, 0, 0];
    data.extend_from_slice(&(width - 1).to_le_bytes()[..3]);
    data.extend_from_slice(&(height - 1).to_le_bytes()[..3]);
    riff(b"VP8X", &data)
}

fn webp_lossy(width: u16, height: u16) -> Vec<u8> {
    let mut data = vec![0, 0, 0, 0x9D, 0x01, 0x2A];
    data.extend_from_slice(&width.to_le_bytes());
    data.extend_from_slice(&height.to_le_bytes());
    riff(b"VP8 ", &data)
}

fn webp_lossless(width: u32, height: u32) -> Vec<u8> {
    let bits = (width - 1) | (height - 1) << 14;
    let mut data = vec![0x2F];
    data.extend_from_slice(&bits.to_le_bytes());
    riff(b"VP8L", &data)
}

#[test]
fn every_format_reports_its_size() {
    let cases: [(Vec<u8>, &str); 6] = [
        (png(640, 480, false), "image/png"),
        (jpeg(640, 480), "image/jpeg"),
        (gif(640, 480, 1), "image/gif"),
        (webp_extended(640, 480, false), "image/webp"),
        (webp_lossy(640, 480), "image/webp"),
        (webp_lossless(640, 480), "image/webp"),
    ];
    for (bytes, content_type) in cases {
        let header = inspect(&bytes).unwrap_or_else(|| panic!("{content_type} did not parse"));
        assert_eq!((header.width, header.height), (640, 480), "{content_type}");
        assert_eq!(header.content_type, content_type);
        assert!(!header.animated, "{content_type} read as animated");
    }
}

#[test]
fn every_animated_format_is_seen_as_animated() {
    for bytes in [
        png(64, 64, true),
        gif(64, 64, 2),
        webp_extended(64, 64, true),
    ] {
        assert!(inspect(&bytes).unwrap().animated);
        assert_eq!(
            check_image(&bytes, Motion::StillOnly, MAX_PROFILE_IMAGE_SIDE),
            Err(ImageProblem::Animated)
        );
        assert!(check_image(&bytes, Motion::AnimatedAllowed, MAX_EMOJI_SIDE).is_ok());
    }
}

#[test]
fn a_tiny_file_declaring_a_huge_canvas_is_refused() {
    let bomb = png(30_000, 30_000, false);
    assert!(bomb.len() < 100);
    assert_eq!(
        check_image(&bomb, Motion::AnimatedAllowed, u32::MAX),
        Err(ImageProblem::TooLarge)
    );
}

#[test]
fn the_side_limit_is_inclusive() {
    let edge = png(MAX_PROFILE_IMAGE_SIDE, 16, false);
    assert!(check_image(&edge, Motion::StillOnly, MAX_PROFILE_IMAGE_SIDE).is_ok());
    let over = png(MAX_PROFILE_IMAGE_SIDE + 1, 16, false);
    assert_eq!(
        check_image(&over, Motion::StillOnly, MAX_PROFILE_IMAGE_SIDE),
        Err(ImageProblem::TooLarge)
    );
    let tall = jpeg(16, (MAX_EMOJI_SIDE + 1) as u16);
    assert_eq!(
        check_image(&tall, Motion::AnimatedAllowed, MAX_EMOJI_SIDE),
        Err(ImageProblem::TooLarge)
    );
}

#[test]
fn a_zero_sized_image_is_unsupported() {
    assert_eq!(
        check_image(
            &png(0, 10, false),
            Motion::StillOnly,
            MAX_PROFILE_IMAGE_SIDE
        ),
        Err(ImageProblem::Unsupported)
    );
}

#[test]
fn non_pictures_and_truncated_headers_are_unsupported() {
    let full = [
        png(64, 64, false),
        jpeg(64, 64),
        gif(64, 64, 1),
        webp_lossy(64, 64),
    ];
    for bytes in full {
        for cut in [9, 14, 20] {
            let truncated = &bytes[..cut.min(bytes.len() - 1)];
            let result = std::panic::catch_unwind(|| inspect(truncated));
            assert!(result.is_ok(), "panicked on a {cut}-byte prefix");
        }
    }
    assert_eq!(inspect(b"%PDF-1.7\n"), None);
    assert_eq!(inspect(b"just some text"), None);
    assert_eq!(inspect(&png(64, 64, false)[..20]), None);
}

#[test]
fn a_png_chunk_length_that_overflows_does_not_panic() {
    let mut bytes = png(64, 64, false);
    bytes[8..12].copy_from_slice(&u32::MAX.to_be_bytes());
    assert_eq!(inspect(&bytes), None);
}
