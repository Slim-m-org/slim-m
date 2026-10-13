// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reads an uploaded image's pixel size and whether it animates from its
//! header, without decoding it, so a picture that would be wrong for its
//! purpose is refused at upload rather than drawn by every client.
//!
//! The size check matters on its own: a few hundred bytes of PNG can declare
//! a 30000x30000 canvas, which passes any byte cap and then asks every viewer
//! to allocate gigabytes to draw it.

use super::content_type::{is_inline, sniff_content_type};

/// No uploaded picture may hold more pixels than this, whatever its purpose.
pub const MAX_IMAGE_PIXELS: u64 = 40_000_000;

/// Longest side of an avatar, Space icon or banner. Clients shrink to well
/// under this before uploading; it bounds what a hand-made request can send.
pub const MAX_PROFILE_IMAGE_SIDE: u32 = 4096;

/// Longest side of a custom emoji, which is never drawn larger than a line of text.
pub const MAX_EMOJI_SIDE: u32 = 1024;

/// What the header says about an image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImageHeader {
    pub content_type: &'static str,
    pub width: u32,
    pub height: u32,
    pub animated: bool,
}

/// Whether a purpose accepts a moving picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Motion {
    StillOnly,
    AnimatedAllowed,
}

/// Why a picture was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageProblem {
    /// Not one of the inline picture types, or a header that does not parse.
    Unsupported,
    /// Moves, where only a still picture belongs.
    Animated,
    /// Wider, taller or larger in pixels than the purpose allows.
    TooLarge,
}

/// Checks `bytes` is a picture fit for a purpose that allows `motion` and
/// sides up to `max_side`.
pub fn check_image(
    bytes: &[u8],
    motion: Motion,
    max_side: u32,
) -> Result<ImageHeader, ImageProblem> {
    let header = inspect(bytes).ok_or(ImageProblem::Unsupported)?;
    if header.width == 0 || header.height == 0 {
        return Err(ImageProblem::Unsupported);
    }
    let pixels = u64::from(header.width) * u64::from(header.height);
    if header.width > max_side || header.height > max_side || pixels > MAX_IMAGE_PIXELS {
        return Err(ImageProblem::TooLarge);
    }
    if header.animated && motion == Motion::StillOnly {
        return Err(ImageProblem::Animated);
    }
    Ok(header)
}

/// The header of an inline picture type, or `None` for anything else or a
/// header too short or malformed to read.
pub fn inspect(bytes: &[u8]) -> Option<ImageHeader> {
    let content_type = sniff_content_type(bytes).filter(|ct| is_inline(ct))?;
    let (width, height, animated) = match content_type {
        "image/png" => png(bytes)?,
        "image/jpeg" => jpeg(bytes)?,
        "image/gif" => gif(bytes)?,
        "image/webp" => webp(bytes)?,
        _ => return None,
    };
    Some(ImageHeader {
        content_type,
        width,
        height,
        animated,
    })
}

fn be16(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from(u16::from_be_bytes(
        b.get(at..at + 2)?.try_into().ok()?,
    )))
}

fn le16(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from(u16::from_le_bytes(
        b.get(at..at + 2)?.try_into().ok()?,
    )))
}

fn be32(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(b.get(at..at + 4)?.try_into().ok()?))
}

fn le24(b: &[u8], at: usize) -> Option<u32> {
    let s = b.get(at..at + 3)?;
    Some(u32::from(s[0]) | u32::from(s[1]) << 8 | u32::from(s[2]) << 16)
}

/// IHDR is always the first chunk; an `acTL` chunk before the image data is
/// what makes a PNG an APNG.
fn png(b: &[u8]) -> Option<(u32, u32, bool)> {
    if b.get(12..16)? != b"IHDR" {
        return None;
    }
    let (width, height) = (be32(b, 16)?, be32(b, 20)?);
    let mut at = 8;
    loop {
        let len = usize::try_from(be32(b, at)?).ok()?;
        match b.get(at + 4..at + 8)? {
            b"acTL" => return Some((width, height, true)),
            b"IDAT" | b"IEND" => return Some((width, height, false)),
            _ => at = at.checked_add(12)?.checked_add(len)?,
        }
    }
}

/// The frame size is in the first start-of-frame segment; scanning stops at
/// start-of-scan, which no well-formed JPEG reaches before one.
fn jpeg(b: &[u8]) -> Option<(u32, u32, bool)> {
    let mut at = 2;
    loop {
        while *b.get(at)? == 0xFF && *b.get(at + 1)? == 0xFF {
            at += 1;
        }
        if *b.get(at)? != 0xFF {
            return None;
        }
        let marker = *b.get(at + 1)?;
        if marker == 0x01 || (0xD0..=0xD8).contains(&marker) {
            at += 2;
            continue;
        }
        if marker == 0xD9 || marker == 0xDA {
            return None;
        }
        let len = usize::try_from(be16(b, at + 2)?).ok()?;
        let is_frame = (0xC0..=0xCF).contains(&marker) && !matches!(marker, 0xC4 | 0xC8 | 0xCC);
        if is_frame {
            return Some((be16(b, at + 7)?, be16(b, at + 5)?, false));
        }
        at = at.checked_add(2)?.checked_add(len)?;
    }
}

/// A GIF animates when it holds more than one image; counting them means
/// walking every block, since a frame count is stored nowhere.
fn gif(b: &[u8]) -> Option<(u32, u32, bool)> {
    let (width, height) = (le16(b, 6)?, le16(b, 8)?);
    let flags = *b.get(10)?;
    let mut at = 13;
    if flags & 0x80 != 0 {
        at += 3 << ((flags & 0x07) + 1);
    }
    let mut frames = 0u32;
    loop {
        match *b.get(at)? {
            0x3B => return Some((width, height, frames > 1)),
            0x21 => at = skip_sub_blocks(b, at + 2)?,
            0x2C => {
                frames += 1;
                if frames > 1 {
                    return Some((width, height, true));
                }
                let local = *b.get(at + 9)?;
                at += 10;
                if local & 0x80 != 0 {
                    at += 3 << ((local & 0x07) + 1);
                }
                at = skip_sub_blocks(b, at + 1)?;
            }
            _ => return None,
        }
    }
}

fn skip_sub_blocks(b: &[u8], mut at: usize) -> Option<usize> {
    loop {
        let len = usize::from(*b.get(at)?);
        at += 1;
        if len == 0 {
            return Some(at);
        }
        at = at.checked_add(len)?;
    }
}

/// The first chunk names the format: VP8X (extended, which carries the
/// animation flag), VP8 (lossy) or VP8L (lossless).
fn webp(b: &[u8]) -> Option<(u32, u32, bool)> {
    match b.get(12..16)? {
        b"VP8X" => {
            let animated = *b.get(20)? & 0x02 != 0;
            Some((le24(b, 24)? + 1, le24(b, 27)? + 1, animated))
        }
        b"VP8 " => {
            if b.get(23..26)? != [0x9D, 0x01, 0x2A] {
                return None;
            }
            Some((le16(b, 26)? & 0x3FFF, le16(b, 28)? & 0x3FFF, false))
        }
        b"VP8L" => {
            if *b.get(20)? != 0x2F {
                return None;
            }
            let bits = u32::from_le_bytes(b.get(21..25)?.try_into().ok()?);
            Some(((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1, false))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests;
