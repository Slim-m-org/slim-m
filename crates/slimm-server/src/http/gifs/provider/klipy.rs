// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Klipy's v1 API: request-building and response-parsing for `search` and
//! `trending`. Checked against real captured responses from a live account
//! (search, trending, and an invalid-key error) - see this module's own
//! parent for why that matters here specifically.

use serde::Deserialize;

use super::{ProviderGif, Rendition, stamp_rendition};

pub(super) const BASE_URL: &str = "https://api.klipy.com";

#[derive(Deserialize)]
struct Response {
    data: Page,
}

#[derive(Deserialize)]
struct Page {
    data: Vec<Item>,
}

#[derive(Deserialize)]
struct Item {
    #[serde(default)]
    title: String,
    #[serde(default)]
    file: FileTiers,
}

/// One quality tier per field rather than a `HashMap`: Klipy documents this
/// exact fixed set (`hd`, `md`, `sm`, `xs`), and a struct makes "this tier is
/// missing on this item" a plain `None` rather than a map lookup. Defaulted
/// as a whole so an item missing the entire `file` object (never observed,
/// but not ruled out) degrades to "no usable format" rather than failing the
/// whole response's parse.
#[derive(Deserialize, Default)]
struct FileTiers {
    hd: Option<Tier>,
    md: Option<Tier>,
    sm: Option<Tier>,
    xs: Option<Tier>,
}

#[derive(Deserialize)]
struct Tier {
    gif: Option<Format>,
    webp: Option<Format>,
}

#[derive(Deserialize)]
struct Format {
    url: String,
    width: u32,
    height: u32,
    #[serde(default)]
    size: Option<u64>,
}

/// The `gif` format over `webp` within one tier, matching Tenor's own
/// gif-first precedent (this deployment's attachment allowlist accepts both,
/// so this is only a default preference, not a hard requirement).
fn pick_format(tier: Option<&Tier>) -> Option<&Format> {
    let tier = tier?;
    tier.gif.as_ref().or(tier.webp.as_ref())
}

/// `xs` is the only tier that is genuinely small on a real account (measured
/// on a sample item: `xs` gif 87x90 100KB vs `hd` gif 220x229 273KB, with `md`
/// and `sm` identical to `hd` on that same item) - it is the one this
/// deployment asks for as a thumbnail. `hd` is the full-resolution image this
/// deployment eventually stores as an attachment. Either falls back through
/// the remaining tiers when its preferred one is missing, degrading
/// gracefully rather than unwrapping, and the whole item is dropped only if
/// nothing usable exists anywhere.
fn item_into_gif(item: Item) -> Option<ProviderGif> {
    let preview = pick_format(item.file.xs.as_ref())
        .or_else(|| pick_format(item.file.sm.as_ref()))
        .or_else(|| pick_format(item.file.md.as_ref()))
        .or_else(|| pick_format(item.file.hd.as_ref()))?;
    let preview_url = preview.url.clone();
    let largest_first: Vec<&Format> = [&item.file.hd, &item.file.md, &item.file.sm, &item.file.xs]
        .into_iter()
        .filter_map(|tier| pick_format(tier.as_ref()))
        .collect();
    let full = *largest_first.first()?;
    let renditions: Vec<Rendition<'_>> = largest_first
        .iter()
        .map(|format| Rendition {
            url: &format.url,
            width: format.width,
            height: format.height,
            size: format.size,
        })
        .collect();
    let stamp_url = stamp_rendition(&renditions)?.to_owned();
    Some(ProviderGif {
        title: item.title,
        preview_url,
        full_url: full.url.clone(),
        width: full.width,
        height: full.height,
        stamp_url,
    })
}

#[derive(Deserialize)]
struct ErrorBody {
    errors: ErrorDetail,
}

#[derive(Deserialize, Default)]
struct ErrorDetail {
    #[serde(default)]
    message: Vec<String>,
}

/// Klipy answers an invalid key with plain HTTP 404 and a body naming the
/// real reason (`{"result":false,"errors":{"message":["The provided API key
/// is invalid."]}}`), which `error_for_status` alone collapses into an opaque
/// "404 Not Found" - confirmed live. An operator debugging a typo'd key
/// deserves the provider's own sentence in the log, not a bare status code.
async fn checked(response: reqwest::Response) -> anyhow::Result<reqwest::Response> {
    if response.status().is_success() {
        return Ok(response);
    }
    let status = response.status();
    let body = response.text().await.unwrap_or_default();
    let message = serde_json::from_str::<ErrorBody>(&body)
        .ok()
        .and_then(|err| err.errors.message.into_iter().next())
        .unwrap_or(body);
    anyhow::bail!("klipy answered {status}: {message}");
}

async fn request(
    http: &reqwest::Client,
    url: String,
    query: &str,
    per_page: &str,
) -> anyhow::Result<Vec<ProviderGif>> {
    let mut params = vec![("page", "1"), ("per_page", per_page)];
    if !query.is_empty() {
        params.push(("q", query));
    }
    let response = http.get(url).query(&params).send().await?;
    let response = checked(response).await?;
    let parsed: Response = response.json().await?;
    Ok(parsed
        .data
        .data
        .into_iter()
        .filter_map(item_into_gif)
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
    let url = format!("{base}/api/v1/{api_key}/gifs/search");
    request(http, url, query, &limit.to_string()).await
}

/// Klipy's own trending endpoint - confirmed live, same paginated
/// `data.data[]` shape as `/gifs/search`, just with no `q` parameter.
pub(super) async fn trending(
    http: &reqwest::Client,
    base_url: Option<&str>,
    api_key: &str,
    limit: u32,
) -> anyhow::Result<Vec<ProviderGif>> {
    let base = base_url.unwrap_or(BASE_URL);
    let url = format!("{base}/api/v1/{api_key}/gifs/trending");
    request(http, url, "", &limit.to_string()).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    /// Shaped exactly like a real captured Klipy `/gifs/search` response:
    /// `{"data": {"data": [{"title", "file": {"hd": {"gif": {"url", "width",
    /// "height", ...}, "webp": {...}}, "xs": {...}}}]}}`. This is the fixture
    /// that proves the old `files: {preview, gif, webp}` shape this module
    /// shipped with would have failed to parse at all.
    #[test]
    fn uses_xs_gif_for_preview_and_hd_gif_for_full() {
        let raw = r#"{
            "result": true,
            "data": {
                "data": [
                    {
                        "id": 1,
                        "title": "a dog nodding",
                        "file": {
                            "hd": {
                                "gif": {"url": "https://klipy.example/hd.gif", "width": 220, "height": 229, "size": 273268},
                                "webp": {"url": "https://klipy.example/hd.webp", "width": 220, "height": 230, "size": 71688}
                            },
                            "xs": {
                                "gif": {"url": "https://klipy.example/xs.gif", "width": 87, "height": 90, "size": 100000},
                                "webp": {"url": "https://klipy.example/xs.webp", "width": 87, "height": 90, "size": 29000}
                            }
                        }
                    }
                ]
            }
        }"#;
        let parsed: Response = serde_json::from_str(raw).unwrap();
        let gifs: Vec<ProviderGif> = parsed
            .data
            .data
            .into_iter()
            .filter_map(item_into_gif)
            .collect();
        assert_eq!(gifs.len(), 1);
        assert_eq!(gifs[0].title, "a dog nodding");
        assert_eq!(gifs[0].preview_url, "https://klipy.example/xs.gif");
        assert_eq!(gifs[0].full_url, "https://klipy.example/hd.gif");
        assert_eq!((gifs[0].width, gifs[0].height), (220, 229));
    }

    fn stamp_of(tiers: Value) -> String {
        let raw =
            json!({"result": true, "data": {"data": [{"id": 1, "title": "t", "file": tiers}]}});
        let parsed: Response = serde_json::from_value(raw).unwrap();
        let gif = parsed
            .data
            .data
            .into_iter()
            .find_map(item_into_gif)
            .unwrap();
        gif.stamp_url
    }

    fn tier(name: &str, side: u32, size: u64) -> Value {
        json!({"gif": {"url": format!("https://klipy.example/{name}.gif"), "width": side, "height": side, "size": size}})
    }

    /// The owner's pick: `hd` was 10.8 MB, past the stamp route's 8 MiB.
    #[test]
    fn a_stamp_takes_the_largest_tier_a_tile_animates() {
        let tiers = json!({
            "hd": tier("hd", 498, 10_854_357),
            "md": tier("md", 320, 900_000),
            "xs": tier("xs", 90, 40_000),
        });
        assert_eq!(stamp_of(tiers), "https://klipy.example/md.gif");
    }

    #[test]
    fn a_stamp_takes_the_full_file_when_it_animates() {
        let tiers = json!({"hd": tier("hd", 220, 273_268), "xs": tier("xs", 87, 100_000)});
        assert_eq!(stamp_of(tiers), "https://klipy.example/hd.gif");
    }

    #[test]
    fn a_stamp_takes_the_smallest_tier_when_none_animates() {
        let tiers = json!({
            "hd": tier("hd", 2000, 30_000_000),
            "sm": tier("sm", 1600, 9_000_000),
            "xs": tier("xs", 1200, 5_000_000),
        });
        assert_eq!(stamp_of(tiers), "https://klipy.example/xs.gif");
    }

    /// A tier missing its `gif` format falls back to `webp`, which this
    /// deployment's own attachment allowlist already accepts.
    #[test]
    fn falls_back_to_webp_when_gif_is_absent_in_a_tier() {
        let raw = r#"{
            "result": true,
            "data": {
                "data": [
                    {
                        "id": 1,
                        "title": "webp only",
                        "file": {
                            "hd": {
                                "webp": {"url": "https://klipy.example/hd.webp", "width": 220, "height": 229, "size": 1}
                            },
                            "xs": {
                                "webp": {"url": "https://klipy.example/xs.webp", "width": 87, "height": 90, "size": 1}
                            }
                        }
                    }
                ]
            }
        }"#;
        let parsed: Response = serde_json::from_str(raw).unwrap();
        let gifs: Vec<ProviderGif> = parsed
            .data
            .data
            .into_iter()
            .filter_map(item_into_gif)
            .collect();
        assert_eq!(gifs.len(), 1);
        assert_eq!(gifs[0].preview_url, "https://klipy.example/xs.webp");
        assert_eq!(gifs[0].full_url, "https://klipy.example/hd.webp");
    }

    /// A missing `xs` tier falls back through `sm`, `md`, `hd` for the
    /// preview rather than dropping the whole item.
    #[test]
    fn falls_back_through_tiers_when_xs_is_missing() {
        let raw = r#"{
            "result": true,
            "data": {
                "data": [
                    {
                        "id": 1,
                        "title": "no xs tier",
                        "file": {
                            "hd": {
                                "gif": {"url": "https://klipy.example/hd.gif", "width": 220, "height": 229, "size": 1}
                            }
                        }
                    }
                ]
            }
        }"#;
        let parsed: Response = serde_json::from_str(raw).unwrap();
        let gifs: Vec<ProviderGif> = parsed
            .data
            .data
            .into_iter()
            .filter_map(item_into_gif)
            .collect();
        assert_eq!(gifs.len(), 1);
        assert_eq!(gifs[0].preview_url, "https://klipy.example/hd.gif");
        assert_eq!(gifs[0].full_url, "https://klipy.example/hd.gif");
    }

    /// An item carrying no usable format anywhere is dropped rather than
    /// passed through with an empty URL, the same rule Tenor already has.
    #[test]
    fn an_item_with_no_usable_format_anywhere_is_dropped() {
        let raw = r#"{
            "result": true,
            "data": {"data": [{"id": 1, "title": "empty", "file": {}}]}
        }"#;
        let parsed: Response = serde_json::from_str(raw).unwrap();
        let gifs: Vec<ProviderGif> = parsed
            .data
            .data
            .into_iter()
            .filter_map(item_into_gif)
            .collect();
        assert!(gifs.is_empty());
    }

    /// Reproduces the real captured Klipy error body for an invalid key:
    /// HTTP 404 with `{"result":false,"errors":{"message":["The provided API
    /// key is invalid."]}}`. `checked` must surface that sentence, not only
    /// the bare status `error_for_status` alone would give an operator -
    /// driven through a real HTTP round trip against a fake local server, not
    /// just a JSON-shape assertion, so the fix is checked against the actual
    /// failure path (`search` calling `checked` on a real
    /// `reqwest::Response`).
    #[tokio::test]
    async fn an_invalid_key_error_surfaces_the_providers_own_sentence() {
        async fn bad_key() -> (axum::http::StatusCode, axum::Json<serde_json::Value>) {
            (
                axum::http::StatusCode::NOT_FOUND,
                axum::Json(serde_json::json!({
                    "result": false,
                    "errors": {"message": ["The provided API key is invalid."]}
                })),
            )
        }

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let router =
            axum::Router::new().route("/api/v1/bad-key/gifs/search", axum::routing::get(bad_key));
        tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });

        let http = reqwest::Client::new();
        let base = format!("http://{addr}");
        let err = search(&http, Some(&base), "bad-key", "cat", 5)
            .await
            .expect_err("an invalid key must not parse as success");
        assert!(
            err.to_string().contains("The provided API key is invalid."),
            "expected the provider's own sentence in the error, got: {err}"
        );
    }
}
