// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Removes a photo's location and other metadata at the container level, so no
//! pixel is decoded and no memory beyond the file itself is held.

use super::exif::{self, Rewrite};
use super::{Kind, Metadata, jpeg_segments};

/// The same file with the policy's metadata removed, or `None` when the format is not handled or nothing needs removing.
pub fn strip(kind: Kind, bytes: &[u8], policy: Metadata) -> Option<Vec<u8>> {
    if policy == Metadata::Keep {
        return None;
    }
    match kind {
        Kind::Jpeg => jpeg_segments::strip(bytes, policy),
        Kind::Png => strip_png(bytes, policy),
        Kind::Webp => strip_webp(bytes, policy),
        _ => None,
    }
}

/// The EXIF block to store in place of `block`, or `None` to store none.
pub fn cleaned_exif(block: &[u8], policy: Metadata) -> Option<Vec<u8>> {
    match policy {
        Metadata::Keep => Some(block.to_vec()),
        Metadata::RemoveLocation => exif::without_location(
            block,
            Rewrite {
                orientation: None,
                dimensions: None,
            },
        )
        .or_else(|| exif::orientation(block).map(exif::orientation_only)),
        Metadata::RemoveAll => exif::orientation(block)
            .filter(|o| *o != 1)
            .map(exif::orientation_only),
    }
}

fn exif_needs_work(block: &[u8], policy: Metadata) -> bool {
    match policy {
        Metadata::Keep => false,
        Metadata::RemoveLocation => exif::has_location(block),
        Metadata::RemoveAll => true,
    }
}

const PNG_SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";

fn strip_png(bytes: &[u8], policy: Metadata) -> Option<Vec<u8>> {
    let mut out = PNG_SIGNATURE.to_vec();
    let mut at = PNG_SIGNATURE.len();
    let mut changed = false;
    while let Some(header) = bytes.get(at..at + 8) {
        let len = u32::from_be_bytes(header[..4].try_into().ok()?) as usize;
        let end = at.checked_add(12)?.checked_add(len)?;
        let chunk = bytes.get(at..end)?;
        let data = &chunk[8..8 + len];
        match png_action(&header[4..8], data, policy) {
            PngAction::Keep => out.extend_from_slice(chunk),
            PngAction::Drop => changed = true,
            PngAction::ReplaceExif(block) => {
                changed = true;
                if let Some(block) = block {
                    push_png_chunk(&mut out, b"eXIf", &block);
                }
            }
        }
        at = end;
    }
    (at == bytes.len() && changed).then_some(out)
}

enum PngAction {
    Keep,
    Drop,
    ReplaceExif(Option<Vec<u8>>),
}

fn png_action(name: &[u8], data: &[u8], policy: Metadata) -> PngAction {
    match name {
        b"eXIf" if exif_needs_work(data, policy) => {
            PngAction::ReplaceExif(cleaned_exif(data, policy))
        }
        b"tEXt" | b"zTXt" | b"iTXt" if text_chunk_goes(data, policy) => PngAction::Drop,
        _ => PngAction::Keep,
    }
}

/// Text chunks that embed an XMP packet or a raw EXIF profile hold the location too.
fn text_chunk_goes(data: &[u8], policy: Metadata) -> bool {
    let keyword = data.split(|b| *b == 0).next().unwrap_or_default();
    match policy {
        Metadata::Keep => false,
        Metadata::RemoveAll => true,
        Metadata::RemoveLocation => {
            keyword == b"XML:com.adobe.xmp" || keyword.starts_with(b"Raw profile type")
        }
    }
}

fn push_png_chunk(out: &mut Vec<u8>, name: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let start = out.len();
    out.extend_from_slice(name);
    out.extend_from_slice(data);
    let crc = crc32(&out[start..]);
    out.extend_from_slice(&crc.to_be_bytes());
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xEDB8_8320 & 0u32.wrapping_sub(crc & 1));
        }
    }
    !crc
}

const WEBP_EXIF_FLAG: u8 = 0x08;
const WEBP_XMP_FLAG: u8 = 0x04;

fn strip_webp(bytes: &[u8], policy: Metadata) -> Option<Vec<u8>> {
    let mut chunks: Vec<(&[u8], Vec<u8>)> = Vec::new();
    let mut at = 12;
    let mut changed = false;
    let (mut exif_left, mut xmp_left) = (false, false);
    while let Some(header) = bytes.get(at..at + 8) {
        let len = u32::from_le_bytes(header[4..8].try_into().ok()?) as usize;
        let end = at.checked_add(8)?.checked_add(len)?;
        let data = bytes.get(at + 8..end)?;
        let name = &header[..4];
        let replaced = match name {
            b"EXIF" if exif_needs_work(data, policy) => Some(cleaned_exif(data, policy)),
            b"XMP " if policy != Metadata::Keep => Some(None),
            _ => None,
        };
        match replaced {
            Some(Some(block)) => {
                changed = true;
                exif_left = true;
                chunks.push((name, block));
            }
            Some(None) => changed = true,
            None => {
                exif_left |= name == b"EXIF";
                xmp_left |= name == b"XMP ";
                chunks.push((name, data.to_vec()));
            }
        }
        at = end + (len & 1);
    }
    if !changed || at < bytes.len() {
        return None;
    }
    let mut body = b"WEBP".to_vec();
    for (name, data) in &mut chunks {
        if *name == b"VP8X" && !data.is_empty() {
            data[0] &= !(if exif_left { 0 } else { WEBP_EXIF_FLAG }
                | if xmp_left { 0 } else { WEBP_XMP_FLAG });
        }
        body.extend_from_slice(name);
        body.extend_from_slice(&(data.len() as u32).to_le_bytes());
        body.extend_from_slice(data);
        if data.len() % 2 == 1 {
            body.push(0);
        }
    }
    let mut out = b"RIFF".to_vec();
    out.extend_from_slice(&u32::try_from(body.len()).ok()?.to_le_bytes());
    out.extend_from_slice(&body);
    Some(out)
}
