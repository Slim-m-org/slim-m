// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Recognizing a playable video link during unfurl, so the client can render
//! a click-to-play affordance instead of loading a third-party player before
//! the reader ever asks for it (see the parent module's privacy note).
//!
//! [`detect`] finds YouTube videos; a Spotify item is recognized by
//! [`super::spotify`] and carried in the same [`VideoInfo`].

use serde::Serialize;
use url::Url;

use super::spotify::SpotifyKind;

/// Whose player a recognized link plays in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub(super) enum VideoProvider {
    #[serde(rename = "youtube")]
    Youtube,
    #[serde(rename = "spotify")]
    Spotify,
}

/// A detected video: which provider, and its canonical id - never a full
/// URL, so the client builds its own embed/watch URL rather than trusting
/// one this server forwarded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct VideoInfo {
    pub provider: VideoProvider,
    pub id: String,
    /// What a Spotify id names; always `None` for YouTube.
    pub kind: Option<SpotifyKind>,
    /// Where a YouTube link asked playback to begin (`t=` or `start=`), in
    /// whole seconds; always `None` for Spotify.
    pub start_s: Option<u32>,
}

/// The longest id accepted. Real YouTube ids are 11 characters; this only
/// guards against a client ever building a URL around something absurd.
const MAX_ID_LEN: usize = 32;

/// The latest start accepted, 100 hours; past any real video.
const MAX_START_S: u32 = 360_000;

/// Detects a playable YouTube video from the page's final URL (a watch page,
/// a `/shorts/` link, an `/embed/` link, or a `youtu.be` short link) or,
/// failing that, an `og:video` URL the page itself declared. The page URL is
/// tried first since a pasted watch link is the common case; `og:video`
/// catches a page that embeds a player without itself being a watch page.
pub(super) fn detect(final_url: &str, og_video: Option<&str>) -> Option<VideoInfo> {
    youtube_video(final_url).or_else(|| og_video.and_then(youtube_video))
}

fn youtube_video(url: &str) -> Option<VideoInfo> {
    let parsed = Url::parse(url).ok()?;
    let id = youtube_id(&parsed)?;
    Some(VideoInfo {
        provider: VideoProvider::Youtube,
        id,
        kind: None,
        start_s: start_seconds(&parsed),
    })
}

/// The `t=` (or `start=`) a shared link carries: plain seconds (`90`,
/// `90s`) or YouTube's `1h2m3s` form. Anything else is no start at all.
fn start_seconds(parsed: &Url) -> Option<u32> {
    let raw = parsed
        .query_pairs()
        .find(|(k, _)| k == "t" || k == "start")
        .map(|(_, v)| v.into_owned())?;
    let seconds = parse_timestamp(&raw)?;
    (seconds > 0 && seconds <= MAX_START_S).then_some(seconds)
}

fn parse_timestamp(raw: &str) -> Option<u32> {
    if let Ok(plain) = raw.parse::<u32>() {
        return Some(plain);
    }
    let mut total: u32 = 0;
    let mut digits = String::new();
    for c in raw.chars() {
        if c.is_ascii_digit() {
            digits.push(c);
            continue;
        }
        let unit = match c {
            'h' => 3600,
            'm' => 60,
            's' => 1,
            _ => return None,
        };
        let value: u32 = digits.parse().ok()?;
        total = total.checked_add(value.checked_mul(unit)?)?;
        digits.clear();
    }
    digits.is_empty().then_some(total)
}

fn youtube_id(parsed: &Url) -> Option<String> {
    let host = parsed.host_str()?;
    let host = host
        .strip_prefix("www.")
        .or_else(|| host.strip_prefix("m."))
        .unwrap_or(host);
    let raw = match host {
        "youtube.com" | "youtube-nocookie.com" if parsed.path() == "/watch" => parsed
            .query_pairs()
            .find(|(k, _)| k == "v")
            .map(|(_, v)| v.into_owned()),
        "youtube.com" | "youtube-nocookie.com" => parsed
            .path()
            .strip_prefix("/shorts/")
            .or_else(|| parsed.path().strip_prefix("/embed/"))
            .map(|rest| first_segment(rest).to_owned()),
        "youtu.be" => Some(first_segment(parsed.path().trim_start_matches('/')).to_owned()),
        _ => None,
    }?;
    valid_id(&raw).then_some(raw)
}

fn first_segment(path: &str) -> &str {
    path.split('/').next().unwrap_or("")
}

/// A YouTube id is alphanumeric plus `-`/`_`; rejecting anything else keeps a
/// stray path segment or query fragment from ever reaching a client-built URL.
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID_LEN
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_a_watch_url() {
        let info = detect("https://www.youtube.com/watch?v=dQw4w9WgXcQ", None).unwrap();
        assert_eq!(info.provider, VideoProvider::Youtube);
        assert_eq!(info.id, "dQw4w9WgXcQ");
    }

    #[test]
    fn recognizes_a_short_link() {
        let info = detect("https://youtu.be/dQw4w9WgXcQ", None).unwrap();
        assert_eq!(info.id, "dQw4w9WgXcQ");
    }

    #[test]
    fn recognizes_a_shorts_url() {
        let info = detect("https://www.youtube.com/shorts/dQw4w9WgXcQ", None).unwrap();
        assert_eq!(info.id, "dQw4w9WgXcQ");
    }

    #[test]
    fn recognizes_a_shorts_url_with_trailing_slash() {
        let info = detect("https://www.youtube.com/shorts/dQw4w9WgXcQ/", None).unwrap();
        assert_eq!(info.id, "dQw4w9WgXcQ");
    }

    #[test]
    fn recognizes_an_embed_url() {
        let info = detect("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ", None).unwrap();
        assert_eq!(info.id, "dQw4w9WgXcQ");
    }

    #[test]
    fn falls_back_to_an_og_video_url_when_the_page_itself_is_not_a_watch_page() {
        let info = detect(
            "https://example.com/blog/post",
            Some("https://www.youtube.com/embed/dQw4w9WgXcQ"),
        )
        .unwrap();
        assert_eq!(info.id, "dQw4w9WgXcQ");
    }

    #[test]
    fn a_non_video_url_is_not_playable() {
        assert!(detect("https://example.com/blog/post", None).is_none());
    }

    #[test]
    fn a_youtube_channel_url_is_not_playable() {
        assert!(detect("https://www.youtube.com/@someuser", None).is_none());
    }

    #[test]
    fn rejects_a_malformed_id() {
        assert!(detect("https://www.youtube.com/watch?v=../../etc", None).is_none());
    }

    #[test]
    fn reads_a_start_time_in_seconds() {
        let info = detect("https://youtu.be/dQw4w9WgXcQ?t=42", None).unwrap();
        assert_eq!(info.start_s, Some(42));
    }

    #[test]
    fn reads_a_start_time_in_hours_minutes_and_seconds() {
        let info = detect("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1h2m3s", None).unwrap();
        assert_eq!(info.start_s, Some(3723));
        let info = detect("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90s", None).unwrap();
        assert_eq!(info.start_s, Some(90));
    }

    #[test]
    fn reads_an_embed_start_parameter() {
        let info = detect(
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?start=15",
            None,
        )
        .unwrap();
        assert_eq!(info.start_s, Some(15));
    }

    #[test]
    fn a_malformed_or_absurd_start_is_no_start() {
        for url in [
            "https://youtu.be/dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ?t=abc",
            "https://youtu.be/dQw4w9WgXcQ?t=1m30",
            "https://youtu.be/dQw4w9WgXcQ?t=0",
            "https://youtu.be/dQw4w9WgXcQ?t=-5",
            "https://youtu.be/dQw4w9WgXcQ?t=999999999999",
            "https://youtu.be/dQw4w9WgXcQ?t=200h",
        ] {
            let info = detect(url, None).unwrap();
            assert_eq!(info.start_s, None, "{url}");
        }
    }

    #[test]
    fn rejects_an_og_video_url_from_an_untrusted_host() {
        assert!(
            detect(
                "https://example.com/blog/post",
                Some("https://evil.example.com/embed/dQw4w9WgXcQ")
            )
            .is_none()
        );
    }
}
