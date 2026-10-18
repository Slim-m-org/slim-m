// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Visually lossless photo compression for uploads, an admin choice.
//!
//! A photograph becomes a smaller upright JPEG that every client draws; a
//! screenshot or drawing stays pixel-identical and only gets smaller bytes;
//! anything that moves, or that no decoder here handles, is left alone. The
//! caller stores the result only when [`compress`] returns one.

mod classify;
mod decode;
mod exif;
mod jpeg_out;
mod jpeg_segments;
mod png_opt;
mod sniff;
#[cfg(test)]
mod tests;

pub use jpeg_encoder::SamplingFactor;
pub use jpeg_out::{DEFAULT as DEFAULT_SETTINGS, Settings, TableKind};
pub use sniff::Kind;

/// The extensions a new deployment lists: photo formats that clients draw or cannot draw at all.
pub const DEFAULT_EXTENSIONS: &[&str] =
    &["jpg", "jpeg", "heic", "heif", "png", "webp", "bmp", "tiff"];

/// Largest file worth reading into memory to look at.
pub const MAX_SOURCE_BYTES: u64 = 256 * 1024 * 1024;
/// Largest picture, in pixels, this module decodes; a bigger one is stored as sent.
pub const MAX_SOURCE_PIXELS: u64 = 160_000_000;
/// A re-encode must save at least this share of the bytes to replace a file that already displays.
const MIN_SAVING_PERCENT: usize = 10;

/// Why an extension list was refused.
#[derive(Debug, PartialEq, Eq)]
pub enum ExtensionError {
    /// Not a plain extension: empty, too long or not letters and digits.
    Malformed(String),
    /// Well formed, but no format this module converts uses it.
    Unsupported(String),
    TooMany,
}

/// Most extensions an admin may list.
const MAX_EXTENSIONS: usize = 24;

const ALL_KINDS: [Kind; 6] = [
    Kind::Jpeg,
    Kind::Png,
    Kind::Webp,
    Kind::Heic,
    Kind::Bmp,
    Kind::Tiff,
];

/// Every extension some supported format answers to.
pub fn supported_extensions() -> Vec<&'static str> {
    ALL_KINDS
        .iter()
        .flat_map(|k| k.extensions().iter().copied())
        .collect()
}

/// Lowercases, drops a leading dot or `*.`, removes duplicates and refuses
/// anything that is not an extension of a supported format.
pub fn normalize_extensions(raw: &[String]) -> Result<Vec<String>, ExtensionError> {
    let supported = supported_extensions();
    let mut out: Vec<String> = Vec::new();
    for entry in raw {
        let ext = entry
            .trim()
            .trim_start_matches("*.")
            .trim_start_matches('.')
            .to_ascii_lowercase();
        if ext.is_empty() || ext.len() > 8 || !ext.bytes().all(|b| b.is_ascii_alphanumeric()) {
            return Err(ExtensionError::Malformed(entry.clone()));
        }
        if !supported.contains(&ext.as_str()) {
            return Err(ExtensionError::Unsupported(ext));
        }
        if !out.contains(&ext) {
            out.push(ext);
        }
    }
    if out.len() > MAX_EXTENSIONS {
        return Err(ExtensionError::TooMany);
    }
    Ok(out)
}

/// What happens to the metadata a photo carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Metadata {
    Keep,
    RemoveLocation,
    RemoveAll,
}

impl Metadata {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Keep => "keep",
            Self::RemoveLocation => "remove_location",
            Self::RemoveAll => "remove_all",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "keep" => Some(Self::Keep),
            "remove_location" => Some(Self::RemoveLocation),
            "remove_all" => Some(Self::RemoveAll),
            _ => None,
        }
    }
}

/// An admin's choices for what to compress and how.
#[derive(Debug, Clone)]
pub struct Policy {
    /// Lowercase extensions, without the dot, that make a sniffed format eligible.
    pub extensions: Vec<String>,
    pub metadata: Metadata,
}

/// The file to store in place of the upload.
#[derive(Debug)]
pub struct Compressed {
    pub bytes: Vec<u8>,
    pub content_type: &'static str,
    pub extension: &'static str,
}

/// A file worth decoding: the format, and how many pixels that costs.
#[derive(Debug, Clone, Copy)]
pub struct Candidate {
    pub kind: Kind,
    pub width: u32,
    pub height: u32,
}

impl Candidate {
    pub fn pixels(&self) -> u64 {
        u64::from(self.width) * u64::from(self.height)
    }
}

/// Whether `prefix` (the file's first bytes) is a format the policy lists.
pub fn eligible_kind(prefix: &[u8], policy: &Policy) -> Option<Kind> {
    let kind = Kind::sniff(prefix)?;
    kind.extensions()
        .iter()
        .any(|ext| policy.extensions.iter().any(|listed| listed == ext))
        .then_some(kind)
}

/// Checks a whole file is a still picture of a size this module will handle.
pub fn inspect(kind: Kind, bytes: &[u8]) -> Option<Candidate> {
    if sniff::is_animated_or_multipage(kind, bytes) {
        return None;
    }
    let (w, h) = dimensions(kind, bytes)?;
    let pixels = u64::from(w) * u64::from(h);
    (pixels > 0 && pixels <= MAX_SOURCE_PIXELS).then_some(Candidate {
        kind,
        width: w,
        height: h,
    })
}

fn dimensions(kind: Kind, bytes: &[u8]) -> Option<(u32, u32)> {
    if kind == Kind::Heic {
        use zune_heic::HeifDecoder;
        use zune_heic::zune_core::bytestream::ZCursor;
        let mut decoder = HeifDecoder::new(ZCursor::new(bytes));
        decoder.decode_headers().ok()?;
        return Some((decoder.width()? as u32, decoder.height()? as u32));
    }
    image::ImageReader::new(std::io::Cursor::new(bytes))
        .with_guessed_format()
        .ok()?
        .into_dimensions()
        .ok()
}

/// The smaller replacement for `bytes`, or `None` to store the upload as sent.
pub fn compress(
    candidate: Candidate,
    bytes: &[u8],
    policy: &Policy,
    settings: &Settings,
) -> Option<Compressed> {
    let kind = candidate.kind;
    let worth_storing = |result: &Compressed| {
        let keeps_format = result.content_type == source_type(kind);
        let smaller = result.bytes.len() * 100 <= bytes.len() * (100 - MIN_SAVING_PERCENT);
        kind.needs_conversion() || smaller || (keeps_format && result.bytes.len() < bytes.len())
    };
    match kind {
        Kind::Jpeg => recompress_photo(candidate, bytes, policy, settings)
            .filter(worth_storing)
            .or_else(|| strip_jpeg(bytes, policy.metadata)),
        _ => convert(candidate, bytes, policy, settings).filter(worth_storing),
    }
}

/// The most memory compressing this file can hold at once, in bytes: the
/// source, the decoded pixels (reduced when a JPEG is decoded at a smaller
/// DCT scale), the resized pixels and a fixed allowance for codec state.
/// Per-pixel factors come from measured peaks in docs/research/media-compression.md.
pub fn peak_bytes(candidate: Candidate, source_len: u64, settings: &Settings) -> u64 {
    let (w, h) = (u64::from(candidate.width), u64::from(candidate.height));
    let edge = w.max(h);
    let cap = u64::from(settings.long_edge);
    let divisor = if candidate.kind == Kind::Jpeg {
        decode::jpeg_scale_divisor(candidate.width, candidate.height, settings.long_edge)
    } else {
        1
    };
    let decoded_px = (w / divisor).max(1) * (h / divisor).max(1);
    let out_px = if edge > cap {
        (w * cap / edge).max(1) * (h * cap / edge).max(1)
    } else {
        decoded_px
    };
    let per_decoded_pixel = match candidate.kind {
        Kind::Jpeg => JPEG_BYTES_PER_PIXEL,
        Kind::Heic => HEIC_BYTES_PER_PIXEL,
        _ => OTHER_BYTES_PER_PIXEL,
    };
    source_len + decoded_px * per_decoded_pixel + out_px * RESIZED_BYTES_PER_PIXEL + FIXED_BYTES
}

const JPEG_BYTES_PER_PIXEL: u64 = 5;
const HEIC_BYTES_PER_PIXEL: u64 = 5;
const OTHER_BYTES_PER_PIXEL: u64 = 8;
const RESIZED_BYTES_PER_PIXEL: u64 = 4;
const FIXED_BYTES: u64 = 24 * 1024 * 1024;

fn source_type(kind: Kind) -> &'static str {
    match kind {
        Kind::Jpeg => "image/jpeg",
        Kind::Png => "image/png",
        Kind::Webp => "image/webp",
        Kind::Heic => "image/heic",
        Kind::Bmp => "image/bmp",
        Kind::Tiff => "image/tiff",
    }
}

fn jpeg(bytes: Vec<u8>) -> Compressed {
    Compressed {
        bytes,
        content_type: "image/jpeg",
        extension: "jpg",
    }
}

fn png(bytes: Vec<u8>) -> Compressed {
    Compressed {
        bytes,
        content_type: "image/png",
        extension: "png",
    }
}

fn strip_jpeg(bytes: &[u8], metadata: Metadata) -> Option<Compressed> {
    jpeg_segments::strip(bytes, metadata).map(jpeg)
}

fn recompress_photo(
    candidate: Candidate,
    bytes: &[u8],
    policy: &Policy,
    settings: &Settings,
) -> Option<Compressed> {
    let decoded = decode::decode(candidate, bytes, settings.long_edge)?;
    jpeg_out::encode(decoded, policy.metadata, settings).map(jpeg)
}

fn convert(
    candidate: Candidate,
    bytes: &[u8],
    policy: &Policy,
    settings: &Settings,
) -> Option<Compressed> {
    let kind = candidate.kind;
    let decoded = decode::decode(candidate, bytes, settings.long_edge)?;
    let transparent = decoded.has_transparency();
    let graphic = !transparent && classify::is_graphic(&decoded.image);
    match (kind, transparent || graphic) {
        (Kind::Png, true) => png_opt::optimize(bytes, policy.metadata).map(png),
        (Kind::Webp, true) => None,
        (_, true) => {
            png_opt::encode(&decoded.image, decoded.icc.as_deref(), policy.metadata).map(png)
        }
        (Kind::Webp, false) if !needs_shrink(&decoded, settings) => None,
        (_, false) => jpeg_out::encode(decoded, policy.metadata, settings).map(jpeg),
    }
}

fn needs_shrink(decoded: &decode::Decoded, settings: &Settings) -> bool {
    decoded.image.width().max(decoded.image.height()) > settings.long_edge
}
