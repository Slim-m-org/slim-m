// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The response headers every stored asset carries, buffered or streamed.

use axum::body::Body;
use axum::http::{HeaderMap, HeaderName, HeaderValue, header};
use axum::response::{IntoResponse, Response};

use crate::media;

/// A fetched attachment's bytes never change (they are keyed by their own
/// content hash), so a client may cache one forever.
const IMMUTABLE_CACHE: &str = "private, max-age=31536000, immutable";

/// Serves already-buffered bytes, for the small assets that are read whole
/// anyway: avatars (`super::users`) and custom emoji (`super::emoji`). Large
/// attachments stream instead, through [`super::attachment_range::serve_ranged`];
/// both share [`apply_asset_headers`], so every asset response carries
/// identical security headers.
pub(crate) fn serve(bytes: Vec<u8>, content_type: &str, filename: &str) -> Response {
    let mut response = Body::from(bytes).into_response();
    apply_asset_headers(response.headers_mut(), content_type, filename);
    response
}

/// [`serve`] for an asset at a fixed URL that an admin can replace, so a cache must revalidate.
pub(crate) fn serve_revalidated(bytes: Vec<u8>, content_type: &str, filename: &str) -> Response {
    let mut response = serve(bytes, content_type, filename);
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-cache"),
    );
    response
}

/// Sets the security and caching headers every asset response carries,
/// buffered ([`serve`]) or streamed ([`serve_ranged`]), so both are governed
/// by one definition rather than two that can drift.
///
/// `content_type` is never trusted from the caller; every call site passes a
/// value this module already sniffed from the stored bytes, so this only ever
/// serves an allowlisted type. The filename is re-sanitized here even though
/// the stored value already was: it is cheap and idempotent, and it means the
/// response never depends on every future write path having remembered to.
pub(super) fn apply_asset_headers(headers: &mut HeaderMap, content_type: &str, filename: &str) {
    let kind = if media::is_inline(content_type) {
        "inline"
    } else {
        "attachment"
    };
    let disposition = content_disposition(kind, filename);

    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(content_type)
            .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream")),
    );
    headers.insert(header::CONTENT_DISPOSITION, disposition);
    // Not a named constant in the `http` crate: it is a non-standard header.
    headers.insert(
        HeaderName::from_static("x-content-type-options"),
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static(IMMUTABLE_CACHE),
    );
}

/// The `Content-Disposition` for `filename`, sanitized again here so a response never depends
/// on every write path having done it. The ASCII fallback and RFC 5987 encoding keep the value
/// printable ASCII, so it cannot fail; the fallback keeps a future change a response, not a panic.
pub(super) fn content_disposition(kind: &str, filename: &str) -> HeaderValue {
    let display = media::sanitize_display_filename(filename);
    let ascii = media::sanitize_filename(&display);
    let disposition = if ascii == display {
        format!("{kind}; filename=\"{ascii}\"")
    } else {
        let encoded = media::rfc5987_encode(&display);
        format!("{kind}; filename=\"{ascii}\"; filename*=UTF-8''{encoded}")
    };
    HeaderValue::from_str(&disposition).unwrap_or_else(|_| HeaderValue::from_static("attachment"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// HTML and SVG sniff to the `text/plain` fallback (see
    /// `media::content_type`'s module doc), so this drives the real `serve`
    /// handler with each and asserts the response a browser actually gets:
    /// a forced download, never an inline render, with `nosniff` set too.
    #[test]
    fn html_and_svg_sniffed_as_text_are_served_as_a_forced_download() {
        for bytes in [
            b"<html><body><script>alert(1)</script></body></html>".to_vec(),
            b"<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"alert(1)\"></svg>".to_vec(),
        ] {
            let content_type = media::sniff_content_type(&bytes);
            assert_eq!(content_type, Some("text/plain"));
            let response = serve(bytes, content_type.unwrap(), "evil.html");

            let disposition = response
                .headers()
                .get(header::CONTENT_DISPOSITION)
                .unwrap()
                .to_str()
                .unwrap();
            assert!(
                disposition.starts_with("attachment"),
                "must never be inline: {disposition}"
            );

            let nosniff = response
                .headers()
                .get(HeaderName::from_static("x-content-type-options"))
                .unwrap();
            assert_eq!(nosniff, "nosniff");
        }
    }

    /// Anything the allowlist does not recognize is stored as generic binary
    /// and goes out as a download under its own name, never rendered.
    #[test]
    fn an_unrecognized_file_is_a_forced_download_under_its_own_name() {
        let bytes = vec![0u8, 1, 2, 3, 0xff];
        let content_type = media::attachment_content_type(&bytes);
        assert_eq!(content_type, media::GENERIC_BINARY);
        let response = serve(bytes, content_type, "Win11.iso");
        let disposition = response
            .headers()
            .get(header::CONTENT_DISPOSITION)
            .unwrap()
            .to_str()
            .unwrap();
        assert!(disposition.starts_with("attachment"), "{disposition}");
        assert!(disposition.contains("Win11.iso"), "{disposition}");
        assert_eq!(
            response
                .headers()
                .get(HeaderName::from_static("x-content-type-options"))
                .unwrap(),
            "nosniff"
        );
    }
}
