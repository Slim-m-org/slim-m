// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Building a YouTube video's preview from its oembed endpoint, instead of
//! scraping the watch page - it serves this bot a consent interstitial with
//! no OpenGraph tags. One request returns title, thumbnail and channel
//! together ([`youtube_preview`]), reusing [`super::fetch`]'s guarded
//! [`super::fetch::follow`] so it gets the exact same SSRF handling and
//! per-hop redirect re-validation the ordinary page fetch does. See decision
//! 0019.
//!
//! Best-effort throughout, matching the rest of link unfurling: a failed,
//! slow, or malformed oembed response degrades to the deterministic
//! thumbnail and a generic title with no channel, never a failed unfurl.

use reqwest::Client;
use url::Url;

use super::extract::{Preview, cap};
use super::fetch::{MAX_HTML_BYTES, follow, read_capped};
use super::ssrf::validate;
use super::video::VideoInfo;

/// YouTube's oembed endpoint. A constant rather than inlined so a test can
/// point [fetch_oembed] at a fake server instead - production always calls
/// with this value.
const YOUTUBE_OEMBED_ENDPOINT: &str = "https://www.youtube.com/oembed";

/// A YouTube video's preview, built without scraping the watch page. Title,
/// thumbnail and channel come from a single oembed request (reliable JSON to
/// any agent, and the same call already carries the channel fields - no
/// second round trip), falling back to the deterministic thumbnail URL and a
/// generic title with no channel if oembed is unavailable (a private or
/// deleted video, a timeout, or any other failure). The id was already
/// parsed from the URL.
pub(super) async fn youtube_preview(
    client: &Client,
    start: &str,
    video: VideoInfo,
    allow_private: bool,
) -> Preview {
    youtube_preview_from(client, start, video, allow_private, YOUTUBE_OEMBED_ENDPOINT).await
}

async fn youtube_preview_from(
    client: &Client,
    start: &str,
    video: VideoInfo,
    allow_private: bool,
    oembed_endpoint: &str,
) -> Preview {
    let oembed = fetch_oembed(client, start, allow_private, oembed_endpoint).await;
    let image = oembed
        .as_ref()
        .and_then(|o| o.thumbnail.clone())
        .filter(|url| validate(url, allow_private).is_ok())
        .or_else(|| {
            let fallback = format!("https://i.ytimg.com/vi/{}/hqdefault.jpg", video.id);
            validate(&fallback, allow_private)
                .is_ok()
                .then_some(fallback)
        });
    let author_url = oembed
        .as_ref()
        .and_then(|o| o.author_url.clone())
        .filter(|url| is_http_url(url));
    Preview {
        title: oembed
            .as_ref()
            .and_then(|o| o.title.clone())
            .or_else(|| Some("YouTube".to_string())),
        description: None,
        image,
        site_name: Some("YouTube".to_string()),
        video_url: None,
        video: Some(video),
        author_name: oembed.and_then(|o| o.author_name),
        author_url,
        duration_s: None,
    }
}

/// Whether [s] parses as an absolute http(s) URL - the bar for an
/// oembed-sourced link this server hands back to a client to open, never
/// fetches itself, so the full SSRF guard does not apply.
fn is_http_url(s: &str) -> bool {
    Url::parse(s).is_ok_and(|u| u.scheme() == "http" || u.scheme() == "https")
}

/// The fields this server reads out of a provider's oembed JSON.
#[derive(Default)]
pub(super) struct OembedData {
    pub title: Option<String>,
    pub thumbnail: Option<String>,
    pub author_name: Option<String>,
    pub author_url: Option<String>,
}

/// Fetches the oembed JSON for [start] from [oembed_endpoint] (YouTube's or
/// Spotify's, or a loopback fake in a test) through the same guarded
/// [`follow`] the page fetch uses. `None` on any failure, which each caller
/// degrades from.
pub(super) async fn fetch_oembed(
    client: &Client,
    start: &str,
    allow_private: bool,
    oembed_endpoint: &str,
) -> Option<OembedData> {
    let mut oembed = Url::parse(oembed_endpoint).ok()?;
    oembed
        .query_pairs_mut()
        .append_pair("url", start)
        .append_pair("format", "json");
    let (_, response) = follow(client, oembed.as_str(), allow_private).await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body = read_capped(response, MAX_HTML_BYTES).await.ok()?;
    let json: serde_json::Value = serde_json::from_slice(&body).ok()?;
    let str_field = |key: &str| {
        json.get(key)
            .and_then(|v| v.as_str())
            .map(|s| cap(s.trim()))
            .filter(|s| !s.is_empty())
    };
    Some(OembedData {
        title: str_field("title"),
        thumbnail: str_field("thumbnail_url"),
        author_name: str_field("author_name"),
        author_url: str_field("author_url"),
    })
}

#[cfg(test)]
mod tests {
    use axum::Router;
    use axum::response::{IntoResponse, Redirect};
    use axum::routing::get;
    use tokio::net::TcpListener;

    use super::super::fetch::build_client;
    use super::super::video::VideoProvider;
    use super::*;

    fn sample_video() -> VideoInfo {
        VideoInfo {
            provider: VideoProvider::Youtube,
            id: "dQw4w9WgXcQ".to_string(),
            kind: None,
            start_s: None,
        }
    }

    /// Binds [router] to loopback and serves it in the background, returning
    /// its `/oembed` URL. Reachable only because every test here builds its
    /// client with `allow_private: true`.
    async fn spawn_fake_oembed(router: Router) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        format!("http://{addr}/oembed")
    }

    #[tokio::test]
    async fn oembed_populates_title_and_channel() {
        let body = serde_json::json!({
            "title": "A great video",
            "author_name": "A Channel",
            "author_url": "https://www.youtube.com/@achannel",
            "thumbnail_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hq.jpg",
        });
        let router = Router::new().route(
            "/oembed",
            get(move || async move { axum::Json(body.clone()) }),
        );
        let endpoint = spawn_fake_oembed(router).await;

        let client = build_client(true);
        let preview = youtube_preview_from(
            &client,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            sample_video(),
            true,
            &endpoint,
        )
        .await;

        assert_eq!(preview.title.as_deref(), Some("A great video"));
        assert_eq!(preview.author_name.as_deref(), Some("A Channel"));
        assert_eq!(
            preview.author_url.as_deref(),
            Some("https://www.youtube.com/@achannel")
        );
        assert_eq!(
            preview.image.as_deref(),
            Some("https://i.ytimg.com/vi/dQw4w9WgXcQ/hq.jpg")
        );
    }

    #[tokio::test]
    async fn a_failed_oembed_degrades_to_the_preview_built_without_it() {
        let router = Router::new().route(
            "/oembed",
            get(|| async { axum::http::StatusCode::INTERNAL_SERVER_ERROR }),
        );
        let endpoint = spawn_fake_oembed(router).await;

        let client = build_client(true);
        let preview = youtube_preview_from(
            &client,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            sample_video(),
            true,
            &endpoint,
        )
        .await;

        assert_eq!(preview.title.as_deref(), Some("YouTube"));
        assert!(preview.author_name.is_none());
        assert!(preview.author_url.is_none());
        assert_eq!(
            preview.image.as_deref(),
            Some("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        );
    }

    #[tokio::test]
    async fn a_redirect_to_a_disallowed_scheme_on_the_oembed_path_is_refused() {
        let router = Router::new().route(
            "/oembed",
            get(|| async { Redirect::to("file:///etc/passwd").into_response() }),
        );
        let endpoint = spawn_fake_oembed(router).await;

        let client = build_client(true);
        // allow_private only bypasses IP-range blocking; the scheme check below still runs (see ssrf::validate).
        let preview = youtube_preview_from(
            &client,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            sample_video(),
            true,
            &endpoint,
        )
        .await;

        assert_eq!(preview.title.as_deref(), Some("YouTube"));
        assert!(preview.author_name.is_none());
    }
}
