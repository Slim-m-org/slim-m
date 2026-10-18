// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Walks a JPEG's marker segments, to read its metadata blocks and to rewrite
//! the file without re-encoding a pixel.

use super::Metadata;
use super::exif::{self, Rewrite};

const EXIF_ID: &[u8] = b"Exif\0\0";
const XMP_ID: &[u8] = b"http://ns.adobe.com/xap/1.0/\0";
const ICC_ID: &[u8] = b"ICC_PROFILE\0";
const APP0: u8 = 0xE0;
const APP1: u8 = 0xE1;
const APP2: u8 = 0xE2;
const APP13: u8 = 0xED;
const APP14: u8 = 0xEE;
const COM: u8 = 0xFE;
const SOS: u8 = 0xDA;

struct Chunk<'a> {
    marker: u8,
    /// The marker, length and payload, plus the entropy-coded data for a scan.
    whole: &'a [u8],
}

impl Chunk<'_> {
    fn payload(&self) -> &[u8] {
        self.whole.get(4..).unwrap_or_default()
    }
}

/// The marker segments from the start of image up to the end of image. `None`
/// when the bytes are not a well-formed JPEG.
fn walk(bytes: &[u8]) -> Option<Vec<Chunk<'_>>> {
    if !bytes.starts_with(&[0xFF, 0xD8]) {
        return None;
    }
    let mut out = Vec::new();
    let mut at = 2;
    loop {
        if *bytes.get(at)? != 0xFF {
            return None;
        }
        match *bytes.get(at + 1)? {
            0xFF => at += 1,
            0xD9 => return Some(out),
            0x01 | 0xD0..=0xD7 => at += 2,
            marker => {
                let len = u16::from_be_bytes([*bytes.get(at + 2)?, *bytes.get(at + 3)?]) as usize;
                let header_end = at.checked_add(2 + len).filter(|_| len >= 2)?;
                let end = if marker == SOS {
                    scan_end(bytes, header_end)?
                } else {
                    header_end
                };
                out.push(Chunk {
                    marker,
                    whole: bytes.get(at..end)?,
                });
                at = end;
            }
        }
    }
}

/// Past the entropy-coded data that follows a scan header: the next marker
/// that is neither a stuffed zero nor a restart.
fn scan_end(bytes: &[u8], mut at: usize) -> Option<usize> {
    while at + 1 < bytes.len() {
        if bytes[at] == 0xFF && !matches!(bytes[at + 1], 0x00 | 0xD0..=0xD7 | 0xFF) {
            return Some(at);
        }
        at += 1;
    }
    None
}

fn app1_with<'a>(chunks: &'a [Chunk], id: &[u8]) -> Option<&'a [u8]> {
    chunks
        .iter()
        .filter(|c| c.marker == APP1)
        .find_map(|c| c.payload().strip_prefix(id))
}

/// The EXIF TIFF block, if the file carries one.
pub fn exif_of(bytes: &[u8]) -> Option<Vec<u8>> {
    app1_with(&walk(bytes)?, EXIF_ID).map(<[u8]>::to_vec)
}

/// The XMP packet, if the file carries one.
pub fn xmp_of(bytes: &[u8]) -> Option<Vec<u8>> {
    app1_with(&walk(bytes)?, XMP_ID).map(<[u8]>::to_vec)
}

fn carries_removable(chunks: &[Chunk], policy: Metadata) -> bool {
    chunks.iter().any(|c| match (policy, c.marker) {
        (Metadata::Keep, _) => false,
        (Metadata::RemoveAll, APP1 | APP13 | COM) => true,
        (Metadata::RemoveLocation, APP13) => true,
        (Metadata::RemoveLocation, APP1) => {
            let p = c.payload();
            p.starts_with(XMP_ID) || p.strip_prefix(EXIF_ID).is_some_and(exif::has_location)
        }
        _ => false,
    })
}

/// The same pixels with the policy's metadata removed. Colour profiles stay,
/// and an orientation tag stays so the picture still shows upright. `None` when
/// nothing needs removing or the bytes are not a JPEG.
pub fn strip(bytes: &[u8], policy: Metadata) -> Option<Vec<u8>> {
    let chunks = walk(bytes)?;
    if !carries_removable(&chunks, policy) {
        return None;
    }
    let source_exif = app1_with(&chunks, EXIF_ID);
    let rewritten = source_exif.and_then(|block| match policy {
        Metadata::RemoveLocation => exif::without_location(
            block,
            Rewrite {
                orientation: None,
                dimensions: None,
            },
        ),
        _ => exif::orientation(block)
            .filter(|o| *o != 1)
            .map(exif::orientation_only),
    });
    let mut out = vec![0xFF, 0xD8];
    let mut exif_done = false;
    for chunk in &chunks {
        let keep = match chunk.marker {
            APP0 | APP14 => true,
            APP2 => chunk.payload().starts_with(ICC_ID),
            APP1 if chunk.payload().starts_with(EXIF_ID) && !exif_done => {
                exif_done = true;
                if let Some(block) = &rewritten {
                    push_app1(&mut out, block);
                }
                false
            }
            0xE1..=0xEF | COM => false,
            _ => true,
        };
        if keep {
            out.extend_from_slice(chunk.whole);
        }
    }
    out.extend_from_slice(&[0xFF, 0xD9]);
    Some(out)
}

/// Appends an EXIF segment holding `tiff`, unless it would not fit one segment.
pub fn push_app1(out: &mut Vec<u8>, tiff: &[u8]) {
    let Ok(len) = u16::try_from(2 + EXIF_ID.len() + tiff.len()) else {
        return;
    };
    out.extend_from_slice(&[0xFF, APP1]);
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(EXIF_ID);
    out.extend_from_slice(tiff);
}
