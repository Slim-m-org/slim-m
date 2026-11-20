// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Spotify links: which item a link names, and its card, built from the
//! page's own tags and Spotify's oEmbed, both through the same guarded
//! [`super::fetch::follow`]. See decision 0123.

use reqwest::Client;
use serde::Serialize;
use url::Url;

use super::extract::Preview;
use super::fetch::{FetchError, fetch_page};
use super::oembed::{OembedData, fetch_oembed};
use super::ssrf::validate;
use super::video::{VideoInfo, VideoProvider};

const SPOTIFY_OEMBED_ENDPOINT: &str = "https://open.spotify.com/oembed";
const PAGE_HOST: &str = "open.spotify.com";
const SHORT_LINK_HOSTS: [&str; 2] = ["spotify.link", "spotify.app.link"];

/// Spotify ids are 22 base62 characters.
const ID_LEN: usize = 22;

/// What a Spotify link names, as its URL path spells it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum SpotifyKind {
    Track,
    Album,
    Playlist,
    Artist,
    Show,
    Episode,
}

impl SpotifyKind {
    const ALL: [Self; 6] = [
        Self::Track,
        Self::Album,
        Self::Playlist,
        Self::Artist,
        Self::Show,
        Self::Episode,
    ];

    fn segment(self) -> &'static str {
        match self {
            Self::Track => "track",
            Self::Album => "album",
            Self::Playlist => "playlist",
            Self::Artist => "artist",
            Self::Show => "show",
            Self::Episode => "episode",
        }
    }

    fn from_segment(segment: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.segment() == segment)
    }
}

/// One Spotify item: its kind and id, never a URL the server was handed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Entity {
    pub kind: SpotifyKind,
    pub id: String,
}

/// The item an `open.spotify.com` link names, past any `intl-xx` and
/// `embed` segment; trailing segments and the query are ignored.
pub(super) fn parse_entity(url: &str) -> Option<Entity> {
    let parsed = Url::parse(url).ok()?;
    if !matches!(parsed.scheme(), "https" | "http") || parsed.host_str()? != PAGE_HOST {
        return None;
    }
    let mut segments = parsed.path_segments()?.peekable();
    segments.next_if(|s| is_locale_segment(s));
    segments.next_if_eq(&"embed");
    let kind = SpotifyKind::from_segment(segments.next()?)?;
    let id = segments.next()?;
    is_valid_id(id).then(|| Entity {
        kind,
        id: id.to_owned(),
    })
}

fn is_locale_segment(segment: &str) -> bool {
    segment.strip_prefix("intl-").is_some_and(|locale| {
        !locale.is_empty() && locale.chars().all(|c| c.is_ascii_alphabetic() || c == '-')
    })
}

fn is_valid_id(id: &str) -> bool {
    id.len() == ID_LEN && id.bytes().all(|b| b.is_ascii_alphanumeric())
}

/// The one URL every share of [entity] is fetched and cached as, so a
/// sharer's `?si=` token never leaves this server.
fn canonical_url(entity: &Entity) -> String {
    format!(
        "https://{PAGE_HOST}/{}/{}",
        entity.kind.segment(),
        entity.id
    )
}

/// The URL a pasted [url] is fetched and cached as: its canonical item URL
/// for a Spotify item, [url] itself otherwise.
pub(super) fn fetch_target(url: &str) -> String {
    parse_entity(url).map_or_else(|| url.to_owned(), |item| canonical_url(&item))
}

/// Whether [url] is a Spotify page or one of Spotify's short links.
pub(super) fn is_spotify_link(url: &str) -> bool {
    host_of(url).is_some_and(|host| host == PAGE_HOST || SHORT_LINK_HOSTS.contains(&host.as_str()))
}

fn is_short_link(url: &str) -> bool {
    host_of(url).is_some_and(|host| SHORT_LINK_HOSTS.contains(&host.as_str()))
}

fn host_of(url: &str) -> Option<String> {
    Url::parse(url).ok()?.host_str().map(str::to_owned)
}

/// The card for a Spotify link. A Spotify page that names no item (a user
/// profile, say) previews like any other page.
pub(super) async fn spotify_preview(
    client: &Client,
    start: &str,
    allow_private: bool,
) -> Result<Option<Preview>, FetchError> {
    if let Some(entity) = parse_entity(start) {
        return item_preview(
            client,
            start,
            entity,
            SPOTIFY_OEMBED_ENDPOINT,
            allow_private,
        )
        .await;
    }
    if is_short_link(start) {
        return short_link_preview(client, start, SPOTIFY_OEMBED_ENDPOINT, allow_private).await;
    }
    Ok(fetch_page(client, start, allow_private)
        .await?
        .map(|(_, preview)| preview))
}

/// [entity]'s card from its page at [page_url] and the oEmbed at
/// [oembed_endpoint], fetched side by side; a test points both at loopback.
pub(super) async fn item_preview(
    client: &Client,
    page_url: &str,
    entity: Entity,
    oembed_endpoint: &str,
    allow_private: bool,
) -> Result<Option<Preview>, FetchError> {
    let (page, oembed) = tokio::join!(
        fetch_page(client, page_url, allow_private),
        fetch_oembed(client, page_url, allow_private, oembed_endpoint),
    );
    let page = match page {
        Err(FetchError::Refused) => return Err(FetchError::Refused),
        loaded => loaded.ok().flatten().map(|(_, preview)| preview),
    };
    if page.is_none() && oembed.is_none() {
        return Err(FetchError::Unavailable);
    }
    Ok(Some(card(
        entity,
        page.unwrap_or_default(),
        oembed.unwrap_or_default(),
        allow_private,
    )))
}

/// A short link names its item only once followed, and Spotify's oEmbed
/// stalls on the short link itself, so oEmbed is asked about the item after.
pub(super) async fn short_link_preview(
    client: &Client,
    short_link: &str,
    oembed_endpoint: &str,
    allow_private: bool,
) -> Result<Option<Preview>, FetchError> {
    let Some((final_url, page)) = fetch_page(client, short_link, allow_private).await? else {
        return Ok(None);
    };
    let Some(entity) = parse_entity(final_url.as_str()) else {
        return Ok(Some(page));
    };
    let item_url = canonical_url(&entity);
    let oembed = fetch_oembed(client, &item_url, allow_private, oembed_endpoint).await;
    Ok(Some(card(
        entity,
        page,
        oembed.unwrap_or_default(),
        allow_private,
    )))
}

/// oEmbed's title is the item's own name where an album's `og:title` reads
/// "Listen to X - EP by Y | Spotify", but a show's names its newest episode.
/// The page's description is Spotify's summary line, and its 640 px cover
/// beats oEmbed's 300 px one.
fn card(entity: Entity, page: Preview, oembed: OembedData, allow_private: bool) -> Preview {
    let thumbnail = oembed
        .thumbnail
        .filter(|url| validate(url, allow_private).is_ok());
    let title = if entity.kind == SpotifyKind::Show {
        page.title.or(oembed.title)
    } else {
        oembed.title.or(page.title)
    };
    Preview {
        title,
        description: page.description,
        image: page.image.or(thumbnail),
        site_name: Some("Spotify".to_owned()),
        video_url: None,
        video: Some(VideoInfo {
            provider: VideoProvider::Spotify,
            id: entity.id,
            kind: Some(entity.kind),
            start_s: None,
        }),
        author_name: None,
        author_url: None,
        duration_s: page.duration_s,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "3ccGTp44b5m3TwTCrolFjw";

    fn entity(url: &str) -> Option<(SpotifyKind, String)> {
        parse_entity(url).map(|e| (e.kind, e.id))
    }

    #[test]
    fn every_kind_parses() {
        for kind in SpotifyKind::ALL {
            let url = format!("https://open.spotify.com/{}/{ID}", kind.segment());
            assert_eq!(entity(&url), Some((kind, ID.to_owned())), "{url}");
        }
    }

    #[test]
    fn locale_embed_trailing_segments_and_the_query_are_skipped() {
        for url in [
            format!("https://open.spotify.com/intl-de/track/{ID}"),
            format!("https://open.spotify.com/intl-pt-BR/track/{ID}"),
            format!("https://open.spotify.com/embed/track/{ID}?utm_source=oembed"),
            format!("https://open.spotify.com/track/{ID}?si=abc123&context=x"),
            format!("http://open.spotify.com/track/{ID}/"),
        ] {
            assert_eq!(
                entity(&url),
                Some((SpotifyKind::Track, ID.to_owned())),
                "{url}"
            );
        }
        let video = format!("https://open.spotify.com/embed/episode/{ID}/video");
        assert_eq!(entity(&video), Some((SpotifyKind::Episode, ID.to_owned())));
    }

    #[test]
    fn a_bad_id_or_another_host_or_path_names_nothing() {
        for url in [
            "https://open.spotify.com/track/3ccGTp44b5m3TwTCrolFj".to_owned(),
            "https://open.spotify.com/track/3ccGTp44b5m3TwTCrolFjwX".to_owned(),
            "https://open.spotify.com/track/3ccGTp44b5m3TwTCrolF-w".to_owned(),
            "https://open.spotify.com/track/3ccGTp44b5m3TwTCrolF%C3%A9".to_owned(),
            format!("https://open.spotify.com.evil.com/track/{ID}"),
            format!("https://evilopen.spotify.com/track/{ID}"),
            format!("https://evil.com/open.spotify.com/track/{ID}"),
            format!("https://open.spotify.com/user/{ID}"),
            "https://open.spotify.com/genre/0JQ5DAqbMKFEC4WFtoNRpw".to_owned(),
            format!("https://open.spotify.com/intl-/track/{ID}"),
            format!("https://open.spotify.com/embed/intl-de/track/{ID}"),
            format!("ftp://open.spotify.com/track/{ID}"),
            "https://open.spotify.com/".to_owned(),
        ] {
            assert_eq!(entity(&url), None, "{url}");
        }
    }

    #[test]
    fn the_canonical_url_drops_everything_but_kind_and_id() {
        let shared = format!("https://open.spotify.com/intl-de/album/{ID}?si=secret");
        let canonical = canonical_url(&parse_entity(&shared).unwrap());
        assert_eq!(canonical, format!("https://open.spotify.com/album/{ID}"));
    }

    #[test]
    fn every_share_of_an_item_fetches_one_url_and_others_are_untouched() {
        let canonical = format!("https://open.spotify.com/track/{ID}");
        for shared in [
            format!("https://open.spotify.com/track/{ID}?si=one"),
            format!("https://open.spotify.com/intl-ja/track/{ID}?si=two#x"),
            canonical.clone(),
        ] {
            assert_eq!(fetch_target(&shared), canonical);
        }
        for other in [
            "https://example.com/a?b=c",
            "https://spotify.link/AbCdEf",
            "https://open.spotify.com/user/someone?si=x",
        ] {
            assert_eq!(fetch_target(other), other);
        }
    }

    #[test]
    fn spotify_links_and_short_links_are_recognized() {
        assert!(is_spotify_link("https://open.spotify.com/user/someone"));
        assert!(is_spotify_link("https://spotify.link/AbCdEf"));
        assert!(is_spotify_link("https://spotify.app.link/AbCdEf"));
        assert!(!is_spotify_link("https://www.spotify.com/us/premium/"));
        assert!(!is_spotify_link(
            "https://open.spotify.com.evil.com/track/x"
        ));
        assert!(!is_spotify_link("not a url"));
    }
}
