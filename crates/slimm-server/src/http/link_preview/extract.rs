// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pulls the preview fields out of a page's HTML head: OpenGraph first, then
//! the plain `<title>`/`<meta name="description">`, then Twitter card tags.
//!
//! A focused scanner over `<meta>` and `<title>`, not a full HTML parse:
//! these tags are a flat shape, the input is already bounded to a head-sized
//! slice by the fetcher, and this keeps the dependency surface small (decision
//! 0019). It handles the real-world variation that trips a naive regex -
//! either attribute order, single or double quotes, and HTML entities in the
//! extracted values - and takes the first value seen for each field.

use super::video::VideoInfo;

/// The metadata a preview card is built from. Every field is optional: a page
/// with only a `<title>` still previews, and a page with nothing usable
/// previews as nothing rather than an error.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Preview {
    pub title: Option<String>,
    pub description: Option<String>,
    pub image: Option<String>,
    pub site_name: Option<String>,
    /// A raw `og:video` URL, if the page declared one - not yet resolved to
    /// an absolute URL or checked against the SSRF guard. [`super::fetch`]
    /// does both before handing it to [`super::video::detect`], which fills
    /// in [`Self::video`].
    pub video_url: Option<String>,
    /// The playable video this page was recognized as, if any. Always `None`
    /// straight out of [`extract`]; [`super::fetch::fetch_preview`] fills it
    /// in once it has this page's final, redirect-resolved URL to check.
    pub video: Option<VideoInfo>,
    /// The page's author or publisher, if known - a YouTube video's channel
    /// name today, from oembed rather than this bounded HTML scan. Always
    /// `None` straight out of [`extract`]; [`super::fetch::youtube_preview`]
    /// fills it in for a recognized video.
    pub author_name: Option<String>,
    /// The author's own page, paired with [`Self::author_name`] - a channel
    /// name a reader cannot click is less useful. Always `None` straight out
    /// of [`extract`].
    pub author_url: Option<String>,
}

impl Preview {
    fn is_empty(&self) -> bool {
        self.title.is_none()
            && self.description.is_none()
            && self.image.is_none()
            && self.site_name.is_none()
            && self.video_url.is_none()
    }
}

/// Longest field values kept; a verbose page cannot make an unbounded card.
/// `pub(super)` so [`super::fetch`] can bound the oembed-sourced author
/// fields the same way, rather than duplicating the constant.
pub(super) const MAX_FIELD_CHARS: usize = 500;

/// Extracts a [`Preview`] from [html], or `None` if nothing usable was found.
pub(super) fn extract(html: &str) -> Option<Preview> {
    let mut p = Preview::default();
    let mut plain_title: Option<String> = None;

    for tag in MetaTags::new(html) {
        match tag {
            Tag::Title(text) => plain_title = plain_title.or(Some(text)),
            Tag::Meta { key, content } => match key.as_str() {
                "og:title" => set(&mut p.title, content),
                "og:description" => set(&mut p.description, content),
                "og:image" | "og:image:url" => set(&mut p.image, content),
                "og:site_name" => set(&mut p.site_name, content),
                "og:video" | "og:video:url" | "og:video:secure_url" => {
                    set(&mut p.video_url, content)
                }
                "twitter:title" => set(&mut p.title, content),
                "twitter:description" => set(&mut p.description, content),
                "twitter:image" | "twitter:image:src" => set(&mut p.image, content),
                "description" => set(&mut p.description, content),
                _ => {}
            },
        }
    }
    // Only fall back to <title> when OpenGraph/Twitter gave no title.
    if p.title.is_none() {
        p.title = plain_title;
    }
    if p.is_empty() { None } else { Some(p) }
}

fn set(field: &mut Option<String>, value: String) {
    if field.is_none() {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            field.replace(cap(trimmed));
        }
    }
}

pub(super) fn cap(s: &str) -> String {
    s.chars().take(MAX_FIELD_CHARS).collect()
}

enum Tag {
    Title(String),
    Meta { key: String, content: String },
}

/// Walks the `<meta>` and `<title>` tags in document order. `<meta>` yields a
/// key (the lowercased `property` or `name`) and its decoded `content`; the
/// first `<title>`'s text is yielded once.
struct MetaTags<'a> {
    rest: &'a str,
    title_done: bool,
}

impl<'a> MetaTags<'a> {
    fn new(html: &'a str) -> Self {
        Self {
            rest: html,
            title_done: false,
        }
    }
}

impl Iterator for MetaTags<'_> {
    type Item = Tag;

    fn next(&mut self) -> Option<Tag> {
        loop {
            let lt = self.rest.find('<')?;
            let after = &self.rest[lt + 1..];
            let lower = after
                .get(..5.min(after.len()))
                .unwrap_or("")
                .to_ascii_lowercase();

            if !self.title_done && lower.starts_with("title") {
                // No `>` after this point means no later tag can end either.
                let open_end = after.find('>')?;
                let content_start = lt + 1 + open_end + 1;
                if let Some(close) = self.rest[content_start..].find("</title") {
                    let text = &self.rest[content_start..content_start + close];
                    self.rest = &self.rest[content_start + close..];
                    self.title_done = true;
                    return Some(Tag::Title(decode_entities(text.trim())));
                }
                // Nothing after this point closes a title, so searching again would rescan the page.
                self.title_done = true;
            }

            let is_meta = lower.starts_with("meta ")
                || lower.starts_with("meta\t")
                || lower.starts_with("meta\n")
                || lower.starts_with("meta>");
            if is_meta {
                let close = after.find('>')?;
                let inner = &after[4..close];
                self.rest = &after[close + 1..];
                if let Some(tag) = parse_meta(inner) {
                    return Some(tag);
                }
                continue;
            }

            // Not a tag we care about; step past this `<` and keep scanning.
            self.rest = after;
        }
    }
}

fn parse_meta(inner: &str) -> Option<Tag> {
    let key = attr(inner, "property").or_else(|| attr(inner, "name"))?;
    let content = attr(inner, "content")?;
    Some(Tag::Meta {
        key: key.to_ascii_lowercase(),
        content: decode_entities(&content),
    })
}

/// The value of attribute [name] in a tag's attribute text, single- or
/// double-quoted. Matches on a word boundary so `property` does not also
/// match inside another attribute's name.
fn attr(inner: &str, name: &str) -> Option<String> {
    let bytes = inner.as_bytes();
    // ASCII lowercasing keeps every byte offset, and doing it per match made a long tag quadratic.
    let lower = inner.to_ascii_lowercase();
    let mut from = 0;
    while let Some(rel) = lower[from..].find(name) {
        let at = from + rel;
        let before_ok = at == 0 || !bytes[at - 1].is_ascii_alphanumeric();
        let mut i = at + name.len();
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if before_ok && i < bytes.len() && bytes[i] == b'=' {
            i += 1;
            while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            if i < bytes.len() && (bytes[i] == b'"' || bytes[i] == b'\'') {
                let quote = bytes[i];
                let start = i + 1;
                let end = inner[start..].find(quote as char)? + start;
                return Some(inner[start..end].to_owned());
            }
        }
        from = at + name.len();
    }
    None
}

/// Decodes the handful of HTML entities that actually show up in OG values.
/// `&amp;` must run last so it does not re-decode an already-decoded `&`.
fn decode_entities(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_opengraph_in_either_attribute_order_and_quote_style() {
        let html = r#"
          <meta property="og:title" content="Hello &amp; Goodbye">
          <meta content='A description' property='og:description'>
          <meta name="og:image" content="https://cdn.example.com/a.png">
          <meta property="og:site_name" content="Example">
        "#;
        let p = extract(html).unwrap();
        assert_eq!(p.title.as_deref(), Some("Hello & Goodbye"));
        assert_eq!(p.description.as_deref(), Some("A description"));
        assert_eq!(p.image.as_deref(), Some("https://cdn.example.com/a.png"));
        assert_eq!(p.site_name.as_deref(), Some("Example"));
    }

    #[test]
    fn falls_back_to_title_and_meta_description() {
        let html = "<head><title>Plain Title</title>\
          <meta name=\"description\" content=\"Meta desc\"></head>";
        let p = extract(html).unwrap();
        assert_eq!(p.title.as_deref(), Some("Plain Title"));
        assert_eq!(p.description.as_deref(), Some("Meta desc"));
    }

    #[test]
    fn opengraph_title_wins_over_plain_title() {
        let html = "<title>Plain</title>\
          <meta property=\"og:title\" content=\"OG Wins\">";
        assert_eq!(extract(html).unwrap().title.as_deref(), Some("OG Wins"));
    }

    #[test]
    fn first_value_wins_for_a_repeated_field() {
        let html = "<meta property=\"og:title\" content=\"First\">\
          <meta property=\"og:title\" content=\"Second\">";
        assert_eq!(extract(html).unwrap().title.as_deref(), Some("First"));
    }

    #[test]
    fn a_page_with_nothing_usable_previews_as_none() {
        assert_eq!(extract("<html><body>no meta here</body></html>"), None);
    }

    #[test]
    fn caps_a_verbose_field() {
        let long = "x".repeat(2000);
        let html = format!("<meta property=\"og:title\" content=\"{long}\">");
        assert_eq!(extract(&html).unwrap().title.unwrap().chars().count(), 500);
    }

    #[test]
    fn reads_an_og_video_url() {
        let html =
            r#"<meta property="og:video" content="https://www.youtube.com/embed/dQw4w9WgXcQ">"#;
        assert_eq!(
            extract(html).unwrap().video_url.as_deref(),
            Some("https://www.youtube.com/embed/dQw4w9WgXcQ")
        );
    }

    #[test]
    fn a_page_with_only_an_og_video_url_still_previews() {
        let html =
            r#"<meta property="og:video:url" content="https://www.youtube.com/embed/dQw4w9WgXcQ">"#;
        assert!(extract(html).is_some());
    }

    #[test]
    fn a_title_that_never_closes_does_not_hide_the_tags_after_it() {
        let html = "<title>never closed <meta property=\"og:title\" content=\"Still here\">";
        assert_eq!(extract(html).unwrap().title.as_deref(), Some("Still here"));
    }

    #[test]
    fn a_tag_that_never_closes_ends_the_scan() {
        let html = "<meta property=\"og:title\" content=\"Fine\"><meta property=\"og:description";
        let p = extract(html).unwrap();
        assert_eq!(p.title.as_deref(), Some("Fine"));
        assert_eq!(p.description, None);
    }

    /// Hostile pages fill the whole 256 KiB fetch bound; each must scan in linear time.
    fn assert_scans_quickly(html: &str) {
        let started = std::time::Instant::now();
        let _ = extract(html);
        let took = started.elapsed();
        assert!(
            took < std::time::Duration::from_millis(500),
            "scan took {took:?}"
        );
    }

    #[test]
    fn a_tag_of_repeated_attribute_names_scans_in_linear_time() {
        let filler = "property ".repeat(28_000);
        assert_scans_quickly(&format!("<meta {filler}>"));
    }

    #[test]
    fn repeated_unclosed_titles_scan_in_linear_time() {
        assert_scans_quickly(&"<title>".repeat(37_000));
    }
}
