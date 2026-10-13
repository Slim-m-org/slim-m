// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Picture bytes whose headers parse: the server reads an upload's size and
//! animation from its header, so a bare magic number is no longer a picture.

fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut out = u32::try_from(data.len()).unwrap().to_be_bytes().to_vec();
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    out.extend_from_slice(&[0; 4]);
    out
}

/// A still PNG of `width` x `height` whose bytes also carry `filler`, so two
/// calls with different filler hash differently and a test can pad to a size.
pub fn png(width: u32, height: u32, filler: &[u8]) -> Vec<u8> {
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = width.to_be_bytes().to_vec();
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
    out.extend(chunk(b"IHDR", &ihdr));
    out.extend(chunk(b"tEXt", filler));
    out.extend(chunk(b"IDAT", &[0; 8]));
    out.extend(chunk(b"IEND", &[]));
    out
}

/// A small still PNG.
pub fn small_png() -> Vec<u8> {
    png(16, 16, b"")
}

/// A two-frame GIF: the shape a profile picture must refuse.
pub fn animated_gif() -> Vec<u8> {
    let mut out = b"GIF89a\x10\x00\x10\x00\x80\x00\x00".to_vec();
    out.extend_from_slice(&[0; 6]);
    for _ in 0..2 {
        out.extend_from_slice(&[0x21, 0xF9, 4, 0, 0, 0, 0, 0]);
        out.extend_from_slice(&[0x2C, 0, 0, 0, 0, 0x10, 0, 0x10, 0, 0]);
        out.extend_from_slice(&[2, 2, 0x4C, 0x01, 0]);
    }
    out.push(0x3B);
    out
}

/// A small still JPEG: the start-of-frame segment is all the server reads.
pub fn small_jpeg() -> Vec<u8> {
    let mut out = vec![
        0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8, 0, 16, 0, 16, 1, 1, 0x11, 0,
    ];
    out.extend_from_slice(&[0xFF, 0xD9]);
    out
}
