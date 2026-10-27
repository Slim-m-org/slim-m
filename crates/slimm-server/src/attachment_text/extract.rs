// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pulling searchable text out of an attachment's bytes, bounded on every axis.
//!
//! The server runs in roughly 512 MiB, so each limit here is a hard cap: how
//! many bytes are read from disk, how many pages of a PDF are visited, and how
//! many characters are kept.

/// Bytes read from a text or code file; the rest is ignored.
pub const MAX_TEXT_FILE_BYTES: u64 = 1024 * 1024;
/// A PDF cannot be cut short and still parse, so a larger one is skipped.
pub const MAX_PDF_BYTES: u64 = 8 * 1024 * 1024;
/// Characters stored per attachment.
pub const MAX_STORED_CHARS: usize = 100_000;
const MAX_PDF_PAGES: usize = 100;
const BINARY_SNIFF_BYTES: usize = 8 * 1024;

const TEXT_EXTENSIONS: &[&str] = &[
    "txt", "md", "markdown", "rst", "log", "csv", "tsv", "json", "yaml", "yml", "toml", "ini",
    "conf", "cfg", "env", "xml", "html", "htm", "css", "scss", "js", "mjs", "ts", "tsx", "jsx",
    "py", "rb", "rs", "go", "java", "kt", "swift", "c", "h", "cc", "cpp", "hpp", "cs", "dart",
    "php", "lua", "sh", "bash", "zsh", "ps1", "sql", "gradle", "tex", "diff", "patch",
];

const TEXT_APPLICATION_TYPES: &[&str] = &[
    "application/json",
    "application/xml",
    "application/x-yaml",
    "application/yaml",
    "application/toml",
    "application/javascript",
    "application/x-sh",
    "application/sql",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Text,
    Pdf,
}

impl Kind {
    /// The most bytes worth reading from disk for this kind.
    pub fn read_limit(self) -> u64 {
        match self {
            Kind::Text => MAX_TEXT_FILE_BYTES,
            Kind::Pdf => MAX_PDF_BYTES,
        }
    }
}

/// What to do with an attachment, by its sniffed type and the name it was sent as.
pub fn kind_of(filename: Option<&str>, content_type: &str) -> Option<Kind> {
    if content_type == "application/pdf" {
        return Some(Kind::Pdf);
    }
    if content_type.starts_with("text/") || TEXT_APPLICATION_TYPES.contains(&content_type) {
        return Some(Kind::Text);
    }
    let extension = filename?.rsplit_once('.')?.1.to_ascii_lowercase();
    if extension == "pdf" {
        return Some(Kind::Pdf);
    }
    TEXT_EXTENSIONS
        .contains(&extension.as_str())
        .then_some(Kind::Text)
}

/// The text of `bytes`, or `None` when there is none to find: a binary file,
/// an encrypted or unreadable PDF, or a scanned one with no text layer.
pub fn extract(kind: Kind, bytes: &[u8]) -> Option<String> {
    let raw = match kind {
        Kind::Text => text_of(bytes)?,
        Kind::Pdf => pdf_text_of(bytes)?,
    };
    let tidy = squeeze(&raw);
    (!tidy.is_empty()).then_some(tidy)
}

fn text_of(bytes: &[u8]) -> Option<String> {
    let head = &bytes[..bytes.len().min(BINARY_SNIFF_BYTES)];
    if head.contains(&0) {
        return None;
    }
    Some(String::from_utf8_lossy(bytes).into_owned())
}

fn pdf_text_of(bytes: &[u8]) -> Option<String> {
    let document = lopdf::Document::load_mem(bytes).ok()?;
    if document.is_encrypted() {
        return None;
    }
    let mut collected = String::new();
    for page in document.get_pages().keys().take(MAX_PDF_PAGES) {
        if let Ok(text) = document.extract_text(&[*page]) {
            collected.push_str(&text);
            collected.push(' ');
        }
        if collected.chars().count() >= MAX_STORED_CHARS {
            break;
        }
    }
    Some(collected)
}

/// Collapses whitespace runs and caps the length at a character boundary.
fn squeeze(raw: &str) -> String {
    let mut out = String::new();
    let mut kept = 0;
    for word in raw.split_whitespace() {
        let room = MAX_STORED_CHARS - kept;
        if room == 0 {
            break;
        }
        if kept > 0 {
            out.push(' ');
            kept += 1;
        }
        let take: String = word
            .chars()
            .take(MAX_STORED_CHARS.saturating_sub(kept))
            .collect();
        kept += take.chars().count();
        out.push_str(&take);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_follow_the_type_then_the_extension() {
        assert_eq!(kind_of(None, "application/pdf"), Some(Kind::Pdf));
        assert_eq!(
            kind_of(Some("a.TXT"), "application/octet-stream"),
            Some(Kind::Text)
        );
        assert_eq!(
            kind_of(Some("main.rs"), "application/octet-stream"),
            Some(Kind::Text)
        );
        assert_eq!(kind_of(None, "text/plain"), Some(Kind::Text));
        assert_eq!(kind_of(Some("photo.png"), "image/png"), None);
        assert_eq!(kind_of(None, "application/octet-stream"), None);
    }

    #[test]
    fn binary_bytes_yield_nothing() {
        assert_eq!(extract(Kind::Text, b"abc\0def"), None);
    }

    #[test]
    fn whitespace_collapses_and_the_length_is_capped() {
        assert_eq!(
            extract(Kind::Text, b"  hello \n\n  world\t"),
            Some("hello world".into())
        );
        let long = "word ".repeat(MAX_STORED_CHARS);
        let kept = extract(Kind::Text, long.as_bytes()).unwrap();
        assert!(kept.chars().count() <= MAX_STORED_CHARS);
    }

    #[test]
    fn a_non_pdf_is_not_a_panic() {
        assert_eq!(extract(Kind::Pdf, b"%PDF-1.4 not really"), None);
        assert_eq!(extract(Kind::Pdf, &[]), None);
    }
}
