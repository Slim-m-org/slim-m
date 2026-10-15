// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The upload content-type allowlist: what an attachment may be stored as,
//! decided from the bytes alone, and whether that type is safe to render
//! inline in a browser.
//!
//! Never derived from a filename extension or a client-declared Content-Type
//! header: both are attacker-controlled input, and trusting either is what
//! would turn this into a stored-XSS vector (a client claiming `image/png`
//! or naming a file `photo.png` cannot talk its way into being served as
//! `text/html` or `image/svg+xml` by any means, because neither is ever
//! checked - only the bytes are, against a fixed allowlist that contains
//! neither).
//!
//! ## The `text/plain` fallback, and why it is safe to add
//!
//! Source files, logs, csv, json and yaml have no magic bytes at all, so the
//! only way to admit them is a last-resort heuristic tried after every real
//! signature has failed to match: valid UTF-8, and every character is either
//! tab, newline, carriage return, or not a Unicode control character (which
//! also excludes NUL, since NUL is itself a control character). This is
//! deliberately loose - it is a filter for "plausibly readable text", not a
//! format detector - and three things follow from that looseness, each
//! checked rather than assumed.
//!
//! An HTML or SVG file is entirely printable ASCII/UTF-8 text and passes
//! this check, so it is stored and later served as `text/plain`. That is
//! inert: `is_inline` never marks `text/plain` inline, so `serve`
//! (`http/attachments.rs`) always sends `Content-Disposition: attachment`
//! for it, which forces a save-file dialog in every browser tested rather
//! than a render, and `X-Content-Type-Options: nosniff` on top means the
//! browser is additionally forbidden from second-guessing the declared type
//! and rendering it anyway. Confirmed by tracing the real handler, not
//! assumed: `serve` derives `disposition_kind` from `is_inline(content_type)`
//! with no branch that could make `text/plain` inline, and `nosniff` is set
//! unconditionally on every response the function builds.
//!
//! A UTF-16 file (or any binary that happens to contain only printable
//! ASCII) can be misclassified. Checked against the real sniffer rather than
//! assumed, and one genuine surprise came out of that check: BOM-less UTF-16
//! text (either endianness) is refused outright, since the NUL byte every
//! ASCII-range code unit carries is a control character this scan does not
//! admit, and a UTF-16BE BOM (`\xFE\xFF`) is refused the same way because it
//! is not valid UTF-8 at all. A UTF-16LE BOM (`\xFF\xFE`) is the one real
//! collision, and it is not with this check: those same two bytes also
//! satisfy `is_mp3`'s frame-sync heuristic below, so a UTF-16LE file is
//! stored as `audio/mpeg` rather than `text/plain` - a wrong label, not a
//! hole, since `audio/mpeg` is exactly as inert a forced download as
//! `text/plain` is.
//!
//! **This residual is real, not just theoretical, even after `is_mp3` was
//! tightened to validate the frame header's reserved fields rather than
//! trusting the sync bits alone (see `is_valid_mpeg_frame_header`).**
//! Checked, not assumed: the BOM itself fixes the header's version and layer
//! fields to non-reserved MPEG1/Layer-I values regardless of file content
//! (`0xFE`'s own bits decode that way), so the tightened check's only
//! remaining power over a UTF-16LE file rests entirely on the first content
//! byte's bitrate and sampling-rate bits. Measured over all 256 byte values,
//! 180 (about 70%) still pass; over printable ASCII specifically, 72 of 95
//! still pass. So most real UTF-16LE text - `[0xFF, 0xFE, b'h', 0, b'i', 0]`
//! among them - still sniffs as `audio/mpeg`, not `text/plain`, after this
//! change. The tightening is a real improvement against arbitrary binary; it
//! does not close this specific collision, and that is stated here rather
//! than left to be rediscovered.
//!
//! A binary format that never happens to emit a NUL or a control byte is the
//! remaining general gap, and the failure mode is the same as above: a wrong
//! label on a forced download, never rendering or execution, so it is
//! accepted rather than chased.
//!
//! Whether admitting this fallback turns the allowlist into "almost
//! anything" in practice: yes, for the specific class of bytes that are
//! valid, mostly-printable UTF-8, and that is the point - it is exactly the
//! reference-material class the owner asked to widen, and the type it maps
//! everything in that class to (`text/plain`, forced download) has no
//! rendering surface for any of it to exploit. The allowlist is still a
//! real boundary against everything outside that class: arbitrary binary,
//! and anything carrying a control byte a text editor would not expect.
//!
//! ## Video and audio are never inline
//!
//! The client has no player and falls through to a download tile for
//! anything outside its own explicit inline-image list
//! (`inlineImageTypes` in `attachment_view.dart`), so marking a video or
//! audio type inline here would only widen what a browser is asked to
//! render, for no client-visible benefit. Revisit once the client actually
//! has a player.
//!
//! ## docx/xlsx/odt are zip containers too, and are not disambiguated
//!
//! Telling an Office or OpenDocument file apart from a plain zip needs
//! reading the archive's central directory for a marker entry, and a zip
//! served as a forced download with `nosniff` has no rendering surface
//! either way, whatever the original file actually was - so all of them are
//! simply `application/zip`.

/// One entry in the upload allowlist: the content type stored bytes matching
/// its magic number are served as, and whether that type is safe to render
/// inline in a browser (an image) or must be forced to download.
struct AllowedType {
    content_type: &'static str,
    inline: bool,
    magic: fn(&[u8]) -> bool,
}

/// Whether `bytes` open with an ISO `ftyp` box whose major brand is one of `brands`.
/// Only the major brand counts: an iPhone video lists `heic` among its compatible
/// brands but is still a video.
fn ftyp_brand_in(bytes: &[u8], brands: &[&[u8; 4]]) -> bool {
    bytes.len() >= 12 && &bytes[4..8] == b"ftyp" && brands.iter().any(|b| &bytes[8..12] == *b)
}

/// `text/plain` is last on purpose: every other entry matches on a real
/// signature, so this last-resort heuristic is only ever reached once none
/// of them has already claimed the bytes.
const ALLOWED_TYPES: &[AllowedType] = &[
    AllowedType {
        content_type: "image/png",
        inline: true,
        magic: |b| b.starts_with(b"\x89PNG\r\n\x1a\n"),
    },
    AllowedType {
        content_type: "image/jpeg",
        inline: true,
        magic: |b| b.starts_with(b"\xff\xd8\xff"),
    },
    AllowedType {
        content_type: "image/gif",
        inline: true,
        magic: |b| b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a"),
    },
    AllowedType {
        content_type: "image/webp",
        inline: true,
        magic: |b| b.len() >= 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP",
    },
    AllowedType {
        content_type: "application/pdf",
        inline: false,
        magic: |b| b.starts_with(b"%PDF-"),
    },
    // HEIF and AVIF stills share the ISO `ftyp` box with mp4, so their brands go first.
    AllowedType {
        content_type: "image/heic",
        inline: false,
        magic: |b| ftyp_brand_in(b, &[b"heic", b"heix", b"heim", b"heis", b"hevc", b"hevx"]),
    },
    AllowedType {
        content_type: "image/heif",
        inline: false,
        magic: |b| ftyp_brand_in(b, &[b"mif1", b"msf1"]),
    },
    AllowedType {
        content_type: "image/avif",
        inline: false,
        magic: |b| ftyp_brand_in(b, &[b"avif", b"avis"]),
    },
    AllowedType {
        content_type: "video/mp4",
        inline: false,
        magic: |b| b.len() >= 8 && &b[4..8] == b"ftyp",
    },
    // Deliberately not inline; see this module's doc comment for why.
    AllowedType {
        content_type: "video/webm",
        inline: false,
        magic: is_webm,
    },
    AllowedType {
        content_type: "audio/mpeg",
        inline: false,
        magic: is_mp3,
    },
    AllowedType {
        content_type: "audio/ogg",
        inline: false,
        magic: |b| b.starts_with(b"OggS"),
    },
    AllowedType {
        content_type: "audio/wav",
        inline: false,
        magic: |b| b.len() >= 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WAVE",
    },
    // docx/xlsx/odt sniff as this too, deliberately not disambiguated; see this module's doc comment.
    AllowedType {
        content_type: "application/zip",
        inline: false,
        magic: |b| b.starts_with(b"PK\x03\x04"),
    },
    AllowedType {
        content_type: "application/gzip",
        inline: false,
        magic: |b| b.starts_with(b"\x1f\x8b"),
    },
    AllowedType {
        content_type: "text/plain",
        inline: false,
        magic: is_plain_text,
    },
];

/// EBML's own magic (`\x1A\x45\xDF\xA3`) is shared by WebM and plain
/// Matroska (`.mkv`), since WebM is a constrained profile of the same
/// container format rather than a distinct one; telling them apart means
/// reading the `DocType` element a real encoder writes within the first few
/// dozen bytes of the header. Rather than decoding EBML's variable-length
/// integers to find that element precisely, this looks for the literal
/// ASCII `webm` within a bounded prefix, which every WebM encoder's DocType
/// value contains and a Matroska file's (`matroska`) does not - so a `.mkv`
/// claiming to be webm is refused, not mislabeled.
fn is_webm(bytes: &[u8]) -> bool {
    const EBML_MAGIC: &[u8] = b"\x1a\x45\xdf\xa3";
    if !bytes.starts_with(EBML_MAGIC) {
        return false;
    }
    let prefix = &bytes[..bytes.len().min(256)];
    prefix.windows(4).any(|w| w == b"webm")
}

/// An `ID3` tag covers most real-world MP3s (the id3 crate's own default),
/// and a validated bare frame sync covers the id3-less minority a raw
/// encoder can still produce.
fn is_mp3(bytes: &[u8]) -> bool {
    bytes.starts_with(b"ID3") || is_valid_mpeg_frame_header(bytes)
}

/// The 11-bit frame sync alone (`0xFF` then `0xE0`-masked) is far too loose
/// on its own: it is a coin flip on two bits of the second byte, so it
/// false-positives on plenty of unrelated binary, including a UTF-16LE BOM
/// (see this module's doc comment). This also requires the header's four
/// reserved-value fields to be real MPEG values - version not `01`, layer
/// not `00`, bitrate index not `1111`, sampling-rate index not `11` - the
/// standard frame-header validity check, which a real encoder never emits
/// and arbitrary bytes fail far more often than they pass.
fn is_valid_mpeg_frame_header(bytes: &[u8]) -> bool {
    if bytes.len() < 3 || bytes[0] != 0xFF || (bytes[1] & 0xE0) != 0xE0 {
        return false;
    }
    let version = (bytes[1] >> 3) & 0x03;
    let layer = (bytes[1] >> 1) & 0x03;
    let bitrate_index = bytes[2] >> 4;
    let sampling_rate_index = (bytes[2] >> 2) & 0x03;
    version != 0b01 && layer != 0b00 && bitrate_index != 0b1111 && sampling_rate_index != 0b11
}

/// The last-resort fallback: see this module's doc comment for the full
/// reasoning on what this admits and why that is safe given a forced
/// download. `str::from_utf8` alone already rejects NUL-laden encodings
/// like UTF-16; `is_control` on every remaining character is what excludes
/// NUL explicitly and every other C0/C1 control code but tab/newline/CR.
fn is_plain_text(bytes: &[u8]) -> bool {
    let Ok(text) = std::str::from_utf8(bytes) else {
        return false;
    };
    text.chars()
        .all(|c| matches!(c, '\t' | '\n' | '\r') || !c.is_control())
}

/// Sniffs `bytes` against the allowlist, returning the content type to store
/// and serve it as. `None` means refuse the upload outright.
pub fn sniff_content_type(bytes: &[u8]) -> Option<&'static str> {
    ALLOWED_TYPES
        .iter()
        .find(|t| (t.magic)(bytes))
        .map(|t| t.content_type)
}

/// Whether `content_type` (expected to be one [`sniff_content_type`]
/// returned) is safe to render inline. Everything else is served as a forced
/// download, so a browser is never asked to execute or render content this
/// module cannot vouch for.
pub fn is_inline(content_type: &str) -> bool {
    ALLOWED_TYPES
        .iter()
        .any(|t| t.content_type == content_type && t.inline)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sniffs_images_and_pdf_by_bytes_not_by_claim() {
        assert_eq!(
            sniff_content_type(b"\x89PNG\r\n\x1a\nrest"),
            Some("image/png")
        );
        assert_eq!(sniff_content_type(b"\xff\xd8\xffrest"), Some("image/jpeg"));
        assert_eq!(sniff_content_type(b"GIF89arest"), Some("image/gif"));
        assert_eq!(
            sniff_content_type(b"RIFF\0\0\0\0WEBPrest"),
            Some("image/webp")
        );
        assert_eq!(sniff_content_type(b"%PDF-1.7"), Some("application/pdf"));
        assert_eq!(sniff_content_type(b"<html><script>"), Some("text/plain"));
    }

    fn ftyp(brand: &[u8; 4]) -> Vec<u8> {
        let mut bytes = vec![0, 0, 0, 0x18];
        bytes.extend_from_slice(b"ftyp");
        bytes.extend_from_slice(brand);
        bytes.extend_from_slice(b"\0\0\0\0mif1heic");
        bytes
    }

    #[test]
    fn an_iphone_photo_is_an_image_not_a_video() {
        assert_eq!(sniff_content_type(&ftyp(b"heic")), Some("image/heic"));
        assert_eq!(sniff_content_type(&ftyp(b"mif1")), Some("image/heif"));
        assert_eq!(sniff_content_type(&ftyp(b"avif")), Some("image/avif"));
        assert!(!is_inline("image/heic"), "browsers mostly cannot draw it");
    }

    #[test]
    fn a_video_listing_heic_as_compatible_is_still_a_video() {
        assert_eq!(sniff_content_type(&ftyp(b"qt  ")), Some("video/mp4"));
        assert_eq!(sniff_content_type(&ftyp(b"isom")), Some("video/mp4"));
    }

    #[test]
    fn sniffs_mp4_from_the_ftyp_box_not_the_filename() {
        let mut bytes = vec![0, 0, 0, 0x18];
        bytes.extend_from_slice(b"ftypisom");
        bytes.extend_from_slice(b"rest of the box");
        assert_eq!(sniff_content_type(&bytes), Some("video/mp4"));
        assert_eq!(
            sniff_content_type(b"not-an-mp4-file.mp4-lying-name"),
            Some("text/plain"),
            "a filename lying about being mp4 does not make the bytes mp4"
        );
    }

    fn ebml_with_doctype(doctype: &[u8]) -> Vec<u8> {
        let mut bytes = vec![0x1a, 0x45, 0xdf, 0xa3, 0x00, 0x00, 0x00, 0x00];
        bytes.push(0x42);
        bytes.push(0x82);
        bytes.push(0x80 | doctype.len() as u8);
        bytes.extend_from_slice(doctype);
        bytes
    }

    #[test]
    fn webm_is_recognized_by_doctype_and_mkv_is_refused() {
        assert_eq!(
            sniff_content_type(&ebml_with_doctype(b"webm")),
            Some("video/webm")
        );
        let mkv = ebml_with_doctype(b"matroska");
        assert_ne!(
            sniff_content_type(&mkv),
            Some("video/webm"),
            "a .mkv file's own DocType must not be accepted as webm"
        );
    }

    #[test]
    fn sniffs_mp3_from_id3_or_a_bare_frame_sync() {
        assert_eq!(
            sniff_content_type(b"ID3\x03\x00\x00\x00rest"),
            Some("audio/mpeg")
        );
        assert_eq!(
            sniff_content_type(&[0xFF, 0xFB, 0x90, 0x00]),
            Some("audio/mpeg")
        );
    }

    /// The sync bits alone (`0xFF` then `0xE0`-masked) are not enough: each
    /// case here sets them but trips exactly one of the four reserved-value
    /// checks a real MPEG frame header must never have, so `is_mp3` has to
    /// look past the sync bits to refuse it. `0xFF` is never valid UTF-8
    /// either, so a refused frame sync does not fall through to `text/plain`.
    #[test]
    fn a_frame_sync_with_a_reserved_header_field_is_refused() {
        let reserved_version = [0xFF, 0xEA, 0x60, 0x00];
        let reserved_layer = [0xFF, 0xF8, 0x60, 0x00];
        let reserved_bitrate_index = [0xFF, 0xFB, 0xF0, 0x00];
        let reserved_sampling_rate_index = [0xFF, 0xFB, 0x6C, 0x00];
        for bytes in [
            reserved_version,
            reserved_layer,
            reserved_bitrate_index,
            reserved_sampling_rate_index,
        ] {
            assert_eq!(
                sniff_content_type(&bytes),
                None,
                "sync bits alone must not be enough: {bytes:?}"
            );
        }
    }

    #[test]
    fn sniffs_ogg_and_wav() {
        assert_eq!(sniff_content_type(b"OggSrest"), Some("audio/ogg"));
        assert_eq!(
            sniff_content_type(b"RIFF\0\0\0\0WAVErest"),
            Some("audio/wav")
        );
        assert_ne!(
            sniff_content_type(b"RIFF\0\0\0\0AVI rest"),
            Some("audio/wav"),
            "a RIFF AVI must not be mistyped as wav"
        );
    }

    #[test]
    fn sniffs_zip_and_gzip() {
        assert_eq!(
            sniff_content_type(b"PK\x03\x04rest of a zip"),
            Some("application/zip")
        );
        assert_eq!(
            sniff_content_type(b"\x1f\x8brest of a gzip"),
            Some("application/gzip")
        );
    }

    #[test]
    fn text_plain_is_a_last_resort_admitting_plausible_text() {
        assert_eq!(
            sniff_content_type(b"fn main() {}\nlet x = 2 * 3;\n"),
            Some("text/plain")
        );
        assert_eq!(
            sniff_content_type("caf\u{e9},total\r\n1,2\n".as_bytes()),
            Some("text/plain")
        );
    }

    #[test]
    fn text_plain_refuses_control_bytes_and_invalid_utf8() {
        assert_eq!(sniff_content_type(b"binary\x00null"), None);
        assert_eq!(sniff_content_type(b"escape\x1bcode"), None);
        assert_eq!(
            sniff_content_type(&[0x00, b'h', 0x00, b'i']),
            None,
            "BOM-less UTF-16BE text carries NUL bytes the scan refuses"
        );
        assert_eq!(
            sniff_content_type(&[0xFE, 0xFF, b'h', 0, b'i', 0]),
            None,
            "a UTF-16BE BOM is not valid UTF-8 at all"
        );
    }

    /// The reserved-field tightening above does not close this: a UTF-16LE
    /// BOM fixes the header's version and layer bits to valid MPEG1/Layer-I
    /// values regardless of file content, so only the first content byte's
    /// own bits can still fail the check, and most byte values do not (see
    /// this module's doc comment for the measured rate). Documented and
    /// harmless either way, since `audio/mpeg` is as inert a forced download
    /// as `text/plain` would have been.
    #[test]
    fn a_utf16le_bom_still_collides_with_mp3_after_the_tightening() {
        assert_eq!(
            sniff_content_type(&[0xFF, 0xFE, b'h', 0, b'i', 0]),
            Some("audio/mpeg")
        );
    }

    #[test]
    fn only_the_allowlisted_types_are_inline() {
        assert!(is_inline("image/png"));
        assert!(is_inline("image/jpeg"));
        assert!(is_inline("image/gif"));
        assert!(is_inline("image/webp"));
        assert!(!is_inline("application/pdf"));
        assert!(!is_inline("video/mp4"));
        assert!(!is_inline("video/webm"));
        assert!(!is_inline("audio/mpeg"));
        assert!(!is_inline("audio/ogg"));
        assert!(!is_inline("audio/wav"));
        assert!(!is_inline("application/zip"));
        assert!(!is_inline("application/gzip"));
        assert!(!is_inline("text/plain"));
    }
}
