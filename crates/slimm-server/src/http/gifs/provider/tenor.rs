// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Tenor's v2 API: request-building and response-parsing for `search` and
//! `trending`. Pinned against Tenor's own published v2 docs.

use serde::Deserialize;

use super::{ProviderGif, Rendition, stamp_rendition};

pub(super) const BASE_URL: &str = "https://tenor.googleapis.com";

#[derive(Deserialize)]
struct Response {
    results: Vec<SearchResult>,
}

#[derive(Deserialize)]
struct SearchResult {
    #[serde(default)]
    content_description: String,
    media_formats: MediaFormats,
}

#[derive(Deserialize)]
struct MediaFormats {
    tinygif: Option<Media>,
    #[serde(default)]
    mediumgif: Option<Media>,
    gif: Option<Media>,
}

#[derive(Deserialize)]
struct Media {
    url: String,
    dims: [u32; 2],
    #[serde(default)]
    size: Option<u64>,
}

impl Media {
    fn rendition(&self) -> Rendition<'_> {
        Rendition {
            url: &self.url,
            width: self.dims[0],
            height: self.dims[1],
            size: self.size,
        }
    }
}

/// One result needs `tinygif` for a preview and `gif` for the eventual
/// attachment; either standing in for the other when only one is present
/// keeps a result usable rather than dropping it outright, and a result
/// carrying neither is dropped, since there is nothing to show or store.
fn result_into_gif(result: SearchResult) -> Option<ProviderGif> {
    let preview = result
        .media_formats
        .tinygif
        .as_ref()
        .or(result.media_formats.gif.as_ref())?;
    let full = result
        .media_formats
        .gif
        .as_ref()
        .or(result.media_formats.tinygif.as_ref())?;
    let formats = &result.media_formats;
    let renditions: Vec<Rendition<'_>> = [&formats.gif, &formats.mediumgif, &formats.tinygif]
        .into_iter()
        .filter_map(|media| media.as_ref().map(Media::rendition))
        .collect();
    let stamp_url = stamp_rendition(&renditions)?.to_owned();
    Some(ProviderGif {
        title: result.content_description,
        preview_url: preview.url.clone(),
        full_url: full.url.clone(),
        width: full.dims[0],
        height: full.dims[1],
        stamp_url,
    })
}

async fn request(
    http: &reqwest::Client,
    url: &str,
    api_key: &str,
    query: Option<&str>,
    limit: u32,
) -> anyhow::Result<Vec<ProviderGif>> {
    let limit_str = limit.to_string();
    let mut params = vec![
        ("key", api_key),
        ("client_key", "slim-m"),
        ("limit", &limit_str),
        ("media_filter", "tinygif,mediumgif,gif"),
        ("contentfilter", "medium"),
    ];
    if let Some(query) = query {
        params.push(("q", query));
    }
    let response = http
        .get(url)
        .query(&params)
        .send()
        .await?
        .error_for_status()?;
    let parsed: Response = response.json().await?;
    Ok(parsed
        .results
        .into_iter()
        .filter_map(result_into_gif)
        .collect())
}

pub(super) async fn search(
    http: &reqwest::Client,
    base_url: Option<&str>,
    api_key: &str,
    query: &str,
    limit: u32,
) -> anyhow::Result<Vec<ProviderGif>> {
    let base = base_url.unwrap_or(BASE_URL);
    let url = format!("{base}/v2/search");
    request(http, &url, api_key, Some(query), limit).await
}

/// Tenor's own "what's popular" endpoint, shaped identically to `/v2/search`
/// (same `results[].media_formats`) but with no `q` parameter at all.
pub(super) async fn trending(
    http: &reqwest::Client,
    base_url: Option<&str>,
    api_key: &str,
    limit: u32,
) -> anyhow::Result<Vec<ProviderGif>> {
    let base = base_url.unwrap_or(BASE_URL);
    let url = format!("{base}/v2/featured");
    request(http, &url, api_key, None, limit).await
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Shaped exactly like Tenor's own documented v2 `/search` response
    /// (`next`, `results[].id`, `media_formats.{tinygif,gif}.{url,dims,size}`),
    /// so a change to `result_into_gif` that stops matching it fails here
    /// rather than only against a live key nothing in CI has.
    #[test]
    fn prefers_tinygif_for_preview_and_gif_for_full() {
        let raw = r#"{
            "next": "",
            "results": [
                {
                    "id": "12345",
                    "content_description": "a cat waving",
                    "media_formats": {
                        "tinygif": {"url": "https://tenor.example/preview.gif", "dims": [220, 165], "size": 45000},
                        "gif": {"url": "https://tenor.example/full.gif", "dims": [498, 373], "size": 890000}
                    }
                }
            ]
        }"#;
        let parsed: Response = serde_json::from_str(raw).unwrap();
        let gifs: Vec<ProviderGif> = parsed
            .results
            .into_iter()
            .filter_map(result_into_gif)
            .collect();
        assert_eq!(gifs.len(), 1);
        assert_eq!(gifs[0].title, "a cat waving");
        assert_eq!(gifs[0].preview_url, "https://tenor.example/preview.gif");
        assert_eq!(gifs[0].full_url, "https://tenor.example/full.gif");
        assert_eq!((gifs[0].width, gifs[0].height), (498, 373));
    }

    /// Tenor's `gif` can be past the stamp route's 8 MiB, so a stamp takes `mediumgif`.
    #[test]
    fn a_stamp_takes_mediumgif_when_the_full_gif_is_too_heavy_to_animate() {
        let raw = r#"{
            "next": "",
            "results": [{
                "id": "1",
                "content_description": "a heavy one",
                "media_formats": {
                    "tinygif": {"url": "https://tenor.example/tiny.gif", "dims": [220, 165], "size": 45000},
                    "mediumgif": {"url": "https://tenor.example/medium.gif", "dims": [480, 360], "size": 1200000},
                    "gif": {"url": "https://tenor.example/full.gif", "dims": [498, 373], "size": 9500000}
                }
            }]
        }"#;
        let parsed: Response = serde_json::from_str(raw).unwrap();
        let gif = parsed
            .results
            .into_iter()
            .find_map(result_into_gif)
            .unwrap();
        assert_eq!(gif.full_url, "https://tenor.example/full.gif");
        assert_eq!(gif.stamp_url, "https://tenor.example/medium.gif");
    }

    /// A result missing both usable formats (a media type this deployment
    /// never asks for, or a provider oddity) is dropped rather than passed
    /// through with an empty URL.
    #[test]
    fn a_result_with_neither_usable_format_is_dropped() {
        let raw = r#"{
            "next": "",
            "results": [
                {"id": "1", "content_description": "no formats", "media_formats": {}}
            ]
        }"#;
        let parsed: Response = serde_json::from_str(raw).unwrap();
        let gifs: Vec<ProviderGif> = parsed
            .results
            .into_iter()
            .filter_map(result_into_gif)
            .collect();
        assert!(gifs.is_empty());
    }
}
