// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which photo format a file is, from its bytes, and whether it moves.

/// A still-photo format this module can decode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Jpeg,
    Png,
    Webp,
    Heic,
    Bmp,
    Tiff,
}

const HEIC_BRANDS: &[&[u8; 4]] = &[
    b"heic", b"heix", b"heim", b"heis", b"hevc", b"hevx", b"mif1", b"msf1",
];

impl Kind {
    /// The format of `bytes`, from the file's own signature.
    pub fn sniff(bytes: &[u8]) -> Option<Self> {
        if bytes.starts_with(b"\xff\xd8\xff") {
            Some(Self::Jpeg)
        } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            Some(Self::Png)
        } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
            Some(Self::Webp)
        } else if bytes.len() >= 12
            && &bytes[4..8] == b"ftyp"
            && HEIC_BRANDS.iter().any(|b| &bytes[8..12] == *b)
        {
            Some(Self::Heic)
        } else if bytes.starts_with(b"BM") && bytes.len() >= 26 {
            Some(Self::Bmp)
        } else if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
            Some(Self::Tiff)
        } else {
            None
        }
    }

    /// The filename extensions an admin can list to make this format eligible.
    pub fn extensions(self) -> &'static [&'static str] {
        match self {
            Self::Jpeg => &["jpg", "jpeg", "jpe", "jfif"],
            Self::Png => &["png"],
            Self::Webp => &["webp"],
            Self::Heic => &["heic", "heif", "hif"],
            Self::Bmp => &["bmp"],
            Self::Tiff => &["tif", "tiff"],
        }
    }

    /// A format no client can draw, so converting it is a display fix and not only a saving.
    pub fn needs_conversion(self) -> bool {
        matches!(self, Self::Heic | Self::Bmp | Self::Tiff)
    }
}

/// Whether the file holds more than one picture or frame, which a re-encode would flatten.
pub fn is_animated_or_multipage(kind: Kind, bytes: &[u8]) -> bool {
    match kind {
        Kind::Png => png_has_chunk_before_data(bytes, b"acTL"),
        Kind::Webp => webp_animated(bytes),
        Kind::Tiff => tiff_page_count(bytes) != Some(1),
        _ => false,
    }
}

fn png_has_chunk_before_data(bytes: &[u8], wanted: &[u8; 4]) -> bool {
    let mut at = 8;
    while let Some(header) = bytes.get(at..at + 8) {
        let len = u32::from_be_bytes([header[0], header[1], header[2], header[3]]) as usize;
        let name = &header[4..8];
        if name == wanted {
            return true;
        }
        if name == b"IDAT" || name == b"IEND" {
            return false;
        }
        at = match at.checked_add(12 + len) {
            Some(next) => next,
            None => return false,
        };
    }
    false
}

fn webp_animated(bytes: &[u8]) -> bool {
    let mut at = 12;
    while let Some(header) = bytes.get(at..at + 8) {
        let len = u32::from_le_bytes([header[4], header[5], header[6], header[7]]) as usize;
        match &header[0..4] {
            b"ANIM" | b"ANMF" => return true,
            b"VP8X" => {
                if bytes.get(at + 8).is_some_and(|flags| flags & 0x02 != 0) {
                    return true;
                }
            }
            b"VP8 " | b"VP8L" => return false,
            _ => {}
        }
        at = match at.checked_add(8 + len + (len & 1)) {
            Some(next) => next,
            None => return false,
        };
    }
    false
}

fn tiff_page_count(bytes: &[u8]) -> Option<usize> {
    let little = bytes.starts_with(b"II");
    let u16_at = |at: usize| -> Option<usize> {
        let b: [u8; 2] = bytes.get(at..at + 2)?.try_into().ok()?;
        Some(usize::from(if little {
            u16::from_le_bytes(b)
        } else {
            u16::from_be_bytes(b)
        }))
    };
    let u32_at = |at: usize| -> Option<usize> {
        let b: [u8; 4] = bytes.get(at..at + 4)?.try_into().ok()?;
        Some(
            (if little {
                u32::from_le_bytes(b)
            } else {
                u32::from_be_bytes(b)
            }) as usize,
        )
    };
    let mut ifd = u32_at(4)?;
    let mut pages = 0;
    while ifd != 0 && pages < 64 {
        pages += 1;
        ifd = u32_at(ifd + 2 + u16_at(ifd)? * 12)?;
    }
    Some(pages)
}
