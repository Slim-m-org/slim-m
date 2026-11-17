// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The guarded fetch: an HTTP GET behind [`super::ssrf`], following redirects
//! by hand so every hop is re-validated (reqwest's own redirect follower
//! would skip the literal-host check on a redirect to a numeric IP), and
//! bounded in time and size so a hostile or slow page cannot tie up the
//! server. See decision 0019.

use std::sync::Arc;
use std::time::Duration;

use reqwest::header::{CONTENT_TYPE, LOCATION, USER_AGENT};
use reqwest::redirect::Policy;
use reqwest::{Client, StatusCode};
use url::Url;

use super::extract::{Preview, extract};
use super::oembed;
use super::spotify;
use super::ssrf::{GuardResolver, UrlError, validate};
use super::video;

/// Identifies the fetch as this server's link-preview bot; many sites only
/// emit OpenGraph tags to a real-looking agent, and it is honest about who is
/// asking.
const USER_AGENT_VALUE: &str = "slimm-link-preview/1.0 (+https://github.com/Slim-m-org/slim-m)";

const MAX_REDIRECTS: usize = 5;
pub(super) const MAX_HTML_BYTES: usize = 256 * 1024;
const MAX_IMAGE_BYTES: usize = 5 * 1024 * 1024;
const TOTAL_TIMEOUT: Duration = Duration::from_secs(5);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

/// What went wrong fetching a preview. Coarse on purpose: a caller never
/// learns whether a blocked address existed, only that no preview was made.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum FetchError {
    /// The URL, or a redirect it reached, points somewhere this server must
    /// not dial, or is not a valid http(s) URL.
    Refused,
    /// A well-formed public URL that could not be fetched or had no usable
    /// preview (unreachable, non-2xx, wrong content type, too large, empty).
    Unavailable,
}

impl From<UrlError> for FetchError {
    fn from(_: UrlError) -> Self {
        FetchError::Refused
    }
}

/// The guarded client: its DNS resolver rejects blocked addresses, and its
/// own redirect follower is off because [`follow`] does that by hand.
/// [allow_private] is the `LinkPreviews::for_test` seam; production passes
/// `false`.
pub(super) fn build_client(allow_private: bool) -> Client {
    Client::builder()
        .dns_resolver(Arc::new(GuardResolver { allow_private }))
        // A proxy would do the DNS lookup the guard exists to check (issue 2111).
        .no_proxy()
        .redirect(Policy::none())
        .timeout(TOTAL_TIMEOUT)
        .connect_timeout(CONNECT_TIMEOUT)
        .user_agent(USER_AGENT_VALUE)
        .build()
        .expect("a client with no unusual TLS config always builds")
}

/// GETs [start], following up to [`MAX_REDIRECTS`] redirects, re-validating
/// the scheme and any literal host at every hop. Returns the final URL and
/// its response. Shared by the page fetch, the image fetch, and
/// [`super::oembed`]'s oembed request, so every one of them gets the exact
/// same per-hop SSRF re-validation.
pub(super) async fn follow(
    client: &Client,
    start: &str,
    allow_private: bool,
) -> Result<(Url, reqwest::Response), FetchError> {
    let mut url = validate(start, allow_private)?;
    for _ in 0..=MAX_REDIRECTS {
        let response = client
            .get(url.clone())
            .header(USER_AGENT, USER_AGENT_VALUE)
            .send()
            .await
            .map_err(|_| FetchError::Unavailable)?;
        let status = response.status();
        if status.is_redirection() {
            let location = response
                .headers()
                .get(LOCATION)
                .and_then(|v| v.to_str().ok())
                .ok_or(FetchError::Unavailable)?;
            let next = url.join(location).map_err(|_| FetchError::Unavailable)?;
            url = validate(next.as_str(), allow_private)?;
            continue;
        }
        if status != StatusCode::OK {
            return Err(FetchError::Unavailable);
        }
        return Ok((url, response));
    }
    Err(FetchError::Unavailable)
}

pub(super) async fn read_capped(
    response: reqwest::Response,
    cap: usize,
) -> Result<Vec<u8>, FetchError> {
    crate::net_guard::read_capped(response, cap)
        .await
        .map_err(|_| FetchError::Unavailable)
}

const HEAD_CLOSE: &[u8] = b"</head>";

/// Reads the start of an HTML page: at most [cap] bytes, keeping the first
/// [cap] of a longer page instead of refusing it, and stopping at `</head>`
/// once the head alone already gives a titled preview.
pub(super) async fn read_head(
    mut response: reqwest::Response,
    cap: usize,
) -> Result<Vec<u8>, FetchError> {
    let mut body = Vec::new();
    let mut head_checked = false;
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| FetchError::Unavailable)?
    {
        let search_from = body.len().saturating_sub(HEAD_CLOSE.len() - 1);
        let room = cap - body.len();
        body.extend_from_slice(&chunk[..chunk.len().min(room)]);
        if body.len() >= cap {
            break;
        }
        if !head_checked && let Some(end) = find_head_close(&body, search_from) {
            head_checked = true;
            // A page that streams its tags into the body (Next.js metadata streaming) keeps reading.
            if head_has_title(&body[..end]) {
                body.truncate(end);
                break;
            }
        }
    }
    Ok(body)
}

/// The byte offset just past the first `</head>` at or after [from], in any letter case.
fn find_head_close(body: &[u8], from: usize) -> Option<usize> {
    body.get(from..)?
        .windows(HEAD_CLOSE.len())
        .position(|w| w.eq_ignore_ascii_case(HEAD_CLOSE))
        .map(|at| from + at + HEAD_CLOSE.len())
}

fn head_has_title(head: &[u8]) -> bool {
    extract(&String::from_utf8_lossy(head)).is_some_and(|p| p.title.is_some())
}

fn content_type(response: &reqwest::Response) -> String {
    response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase()
}

/// The preview for [start]: a recognized YouTube video or Spotify item gets
/// its provider's card, anything else the page's own tags.
pub(super) async fn fetch_preview(
    client: &Client,
    start: &str,
    allow_private: bool,
) -> Result<Option<Preview>, FetchError> {
    // YouTube is recognized from the URL, not by scraping: the watch page serves this bot a consent interstitial with no OG tags, so title/thumbnail/channel come from oembed (see the oembed module).
    if let Some(video) = video::detect(start, None) {
        return Ok(Some(
            oembed::youtube_preview(client, start, video, allow_private).await,
        ));
    }
    if spotify::is_spotify_link(start) {
        return spotify::spotify_preview(client, start, allow_private).await;
    }
    Ok(fetch_page(client, start, allow_private)
        .await?
        .map(|(_, preview)| preview))
}

/// Fetches [start]'s HTML and extracts a preview, with any relative
/// `og:image`/`og:video` resolved to an absolute, re-validated URL (an
/// embed URL is normally already absolute, but resolved the same way for
/// consistency) so the caller can proxy the image and [`video::detect`] can
/// check the video. Returns the page's final, redirect-resolved URL beside
/// it; `Ok(None)` when the page loaded but offered no preview.
pub(super) async fn fetch_page(
    client: &Client,
    start: &str,
    allow_private: bool,
) -> Result<Option<(Url, Preview)>, FetchError> {
    let (final_url, response) = follow(client, start, allow_private).await?;
    let ctype = content_type(&response);
    if !ctype.contains("text/html") && !ctype.contains("application/xhtml") {
        return Ok(None);
    }
    let body = read_head(response, MAX_HTML_BYTES).await?;
    let html = String::from_utf8_lossy(&body);
    let Some(mut preview) = extract(&html) else {
        return Ok(None);
    };
    preview.image = preview
        .image
        .as_ref()
        .and_then(|img| final_url.join(img).ok())
        .filter(|abs| validate(abs.as_str(), allow_private).is_ok())
        .map(|abs| abs.to_string());
    let video_url = preview
        .video_url
        .as_ref()
        .and_then(|v| final_url.join(v).ok())
        .map(|abs| abs.to_string());
    preview.video = video::detect(final_url.as_str(), video_url.as_deref());
    Ok(Some((final_url, preview)))
}

/// Fetches [start] as an image for proxying, returning its bytes. The same SSRF guard applies: the image host is as
/// attacker-controlled as the page host.
pub(super) async fn fetch_image(
    client: &Client,
    start: &str,
    allow_private: bool,
) -> Result<Vec<u8>, FetchError> {
    let (_, response) = follow(client, start, allow_private).await?;
    let ctype = content_type(&response);
    if !ctype.starts_with("image/") {
        return Err(FetchError::Unavailable);
    }
    let bytes = read_capped(response, MAX_IMAGE_BYTES).await?;
    if bytes.is_empty() {
        return Err(FetchError::Unavailable);
    }
    Ok(bytes)
}
