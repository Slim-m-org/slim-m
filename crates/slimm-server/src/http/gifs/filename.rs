// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Turns a provider's GIF title into a stored attachment filename, so a saved
//! GIF is findable later rather than a wall of identical "gif.gif".

/// A lowercase, underscore-joined slug of a GIF's title, for a stored
/// filename that is findable later rather than a wall of identical
/// "gif.gif". Runs of anything but ASCII letters and digits collapse to a
/// single `_`; the result is trimmed of leading/trailing `_` and capped so a
/// verbose provider title cannot make an unwieldy name. Empty (a title of
/// only punctuation, or no title at all) falls back to "gif".
pub(super) fn slug_filename(title: &str) -> String {
    let mut slug = String::new();
    let mut pending_underscore = false;
    for c in title.chars() {
        if c.is_ascii_alphanumeric() {
            let separator = usize::from(pending_underscore && !slug.is_empty());
            if slug.len() + separator + 1 > GIF_SLUG_MAX_CHARS {
                break;
            }
            if separator == 1 {
                slug.push('_');
            }
            pending_underscore = false;
            slug.extend(c.to_lowercase());
        } else {
            pending_underscore = true;
        }
    }
    if slug.is_empty() {
        "gif".to_owned()
    } else {
        slug
    }
}

/// Caps [`slug_filename`] so a long provider title (some run to a sentence)
/// cannot produce an unwieldy attachment name.
pub(super) const GIF_SLUG_MAX_CHARS: usize = 48;

/// A plain filename extension for the two content types a GIF ever sniffs
/// to; unreachable for anything else because `sniff_content_type` already
/// refused it above.
pub(super) fn extension_for(content_type: &str) -> &'static str {
    match content_type {
        "image/webp" => "webp",
        _ => "gif",
    }
}
