// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Client filenames made safe for headers and display, and the hex form of content hashes.

/// Longest a sanitized filename may be, in characters.
const FILENAME_MAX_CHARS: usize = 200;

/// Reduces a client-supplied filename to something safe to place inside a
/// quoted `Content-Disposition` header value: printable ASCII plus space
/// only, so a control character (a `\r` or `\n` would otherwise inject a new
/// header line) or non-ASCII text cannot reach the header at all, and no
/// quote, backslash, or path separator, so nothing can break out of the
/// quoted string. The path-separator strip is defence in depth only: storage
/// never uses this value as a path component (files are keyed by content
/// hash or user id), so a `../` sequence in a filename has nowhere to escape
/// to even before sanitizing.
pub fn sanitize_filename(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| {
            let safe = (c.is_ascii_graphic() || c == ' ') && !matches!(c, '"' | '\\' | '/');
            if safe { c } else { '_' }
        })
        .take(FILENAME_MAX_CHARS)
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        "file".to_owned()
    } else {
        trimmed.to_owned()
    }
}

/// The filename people see: their own text, Unicode included, minus what could
/// break a header or mislead the eye - quotes, backslashes, path separators,
/// and every hidden character `hidden_chars` refuses elsewhere, bidi marks
/// that would make `cod.exe` read as `exe.doc` among them. [`sanitize_filename`] still derives the
/// ASCII fallback for the header from it.
pub fn sanitize_display_filename(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| {
            let unsafe_char =
                crate::hidden_chars::is_hidden_char(c) || matches!(c, '"' | '\\' | '/');
            if unsafe_char { '_' } else { c }
        })
        .take(FILENAME_MAX_CHARS)
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        "file".to_owned()
    } else {
        trimmed.to_owned()
    }
}

/// RFC 5987 `ext-value` encoding for a `filename*=UTF-8''...` parameter: every
/// byte outside `attr-char` is percent-encoded, so the result is plain ASCII.
pub fn rfc5987_encode(value: &str) -> String {
    use std::fmt::Write;
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        let attr_char = byte.is_ascii_alphanumeric() || b"!#$&+-.^_`|~".contains(&byte);
        if attr_char {
            out.push(byte as char);
        } else {
            let _ = write!(out, "%{byte:02X}");
        }
    }
    out
}

/// Lowercase hex, matching the idiom already used for the token and identity
/// fingerprint hashes elsewhere in this crate.
pub fn to_hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// Parses a lowercase (or any-case) hex string back to bytes. `None` for
/// anything that is not a well-formed even-length hex string, which a
/// caller treats as "no such attachment" rather than trying to interpret it
/// as a path or otherwise.
pub fn from_hex(s: &str) -> Option<Vec<u8>> {
    if s.is_empty() || !s.len().is_multiple_of(2) || !s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_strips_header_and_path_injection() {
        assert_eq!(sanitize_filename("photo.png"), "photo.png");
        assert_eq!(sanitize_filename("my photo.png"), "my photo.png");
        assert_eq!(
            sanitize_filename("evil\r\nX-Injected: true.png"),
            "evil__X-Injected: true.png"
        );
        assert_eq!(sanitize_filename("say \"hi\".png"), "say _hi_.png");
        assert_eq!(sanitize_filename("../../etc/passwd"), ".._.._etc_passwd");
        assert_eq!(sanitize_filename(""), "file");
        assert_eq!(sanitize_filename("   "), "file");
    }

    #[test]
    fn a_display_filename_keeps_unicode_but_not_header_breakers() {
        assert_eq!(
            sanitize_display_filename("résumé 日本.pdf"),
            "résumé 日本.pdf"
        );
        assert_eq!(sanitize_display_filename("a\r\nb\".pdf"), "a__b_.pdf");
        assert_eq!(
            sanitize_display_filename("doc\u{202e}exe.txt"),
            "doc_exe.txt"
        );
        assert_eq!(sanitize_display_filename("   "), "file");
        assert_eq!(rfc5987_encode("é a.pdf"), "%C3%A9%20a.pdf");
    }

    #[test]
    fn hex_roundtrips() {
        let bytes = vec![0u8, 1, 255, 16, 128];
        let hex = to_hex(&bytes);
        assert_eq!(hex, "0001ff1080");
        assert_eq!(from_hex(&hex), Some(bytes));
        assert_eq!(from_hex("not-hex"), None);
        assert_eq!(from_hex("abc"), None, "odd length is rejected");
    }
}
