// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A Spotify card from a loopback page and oEmbed recorded from the real
//! ones: which source wins each field, and what is left when either is down.
//! Nothing here reaches Spotify.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axum::Router;
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse, Redirect};
use axum::routing::get;
use serde_json::{Value, json};
use tokio::net::TcpListener;

use super::extract::Preview;
use super::fetch::{FetchError, build_client};
use super::spotify::{Entity, SpotifyKind, item_preview, short_link_preview};
use super::video::VideoProvider;

const ALBUM_ID: &str = "2pAFgWMbsD16uudboQWvVY";
const SHOW_ID: &str = "4rOoJ6Egrf8K2IrywzwOMk";

/// The tags `open.spotify.com/album/2pAFgWMbsD16uudboQWvVY` served this bot on 2026-11-16.
const ALBUM_PAGE: &str = r#"<!DOCTYPE html><html><head>
<meta property="og:site_name" content="Spotify"/>
<meta property="og:title" content="Listen to Tell Me Nice Things - EP by Box Fan | Spotify"/>
<meta property="og:description" content="Box Fan &#xB7; EP &#xB7; 2026 &#xB7; 5 songs"/>
<meta property="og:type" content="music.album"/>
<meta property="og:image" content="/image/ab67616d0000b273641232778d4254a1bffb3b5f"/>
<meta name="music:duration" content="1290"/>
</head><body></body></html>"#;

/// The show page's tags; its oEmbed title is the newest episode's.
const SHOW_PAGE: &str = r#"<html><head>
<meta property="og:title" content="The Joe Rogan Experience"/>
<meta property="og:description" content="Podcast · Joe Rogan · The official podcast of comedian Joe Rogan."/>
</head></html>"#;

fn oembed_titled(title: &str) -> Value {
    json!({
        "type": "rich",
        "title": title,
        "thumbnail_url": "https://image-cdn-ak.spotifycdn.com/image/ab67616d00001e02641232778d4254a1bffb3b5f",
        "thumbnail_width": 300,
    })
}

fn album_oembed() -> Value {
    oembed_titled("Tell Me Nice Things")
}

/// A fake Spotify: its base URL, and how many oEmbed requests it has answered.
struct Fake {
    base: String,
    oembed_hits: Arc<AtomicUsize>,
}

/// Serves `/album` and `/show` when [pages_up], [oembed] at `/oembed` (500 when `None`),
/// and `/to-ftp`, a redirect the guard refuses.
async fn fake_spotify(pages_up: bool, oembed: Option<Value>) -> Fake {
    let hits = Arc::new(AtomicUsize::new(0));
    let counted = hits.clone();
    let page = move |html: &'static str| {
        get(move || async move {
            if pages_up {
                Html(html).into_response()
            } else {
                StatusCode::INTERNAL_SERVER_ERROR.into_response()
            }
        })
    };
    let router = Router::new()
        .route("/album", page(ALBUM_PAGE))
        .route("/show", page(SHOW_PAGE))
        .route(
            "/to-ftp",
            get(|| async { Redirect::to("ftp://example.com/").into_response() }),
        )
        .route(
            "/oembed",
            get(move || async move {
                counted.fetch_add(1, Ordering::Relaxed);
                match oembed {
                    Some(body) => axum::Json(body).into_response(),
                    None => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
                }
            }),
        );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    Fake {
        base: format!("http://{addr}"),
        oembed_hits: hits,
    }
}

fn item(kind: SpotifyKind, id: &str) -> Entity {
    Entity {
        kind,
        id: id.to_owned(),
    }
}

async fn card(fake: &Fake, path: &str, entity: Entity) -> Result<Option<Preview>, FetchError> {
    let page = format!("{}/{path}", fake.base);
    let oembed = format!("{}/oembed", fake.base);
    item_preview(&build_client(true), &page, entity, &oembed, true).await
}

async fn album_card(fake: &Fake) -> Result<Option<Preview>, FetchError> {
    card(fake, "album", item(SpotifyKind::Album, ALBUM_ID)).await
}

#[tokio::test]
async fn the_oembed_title_wins_and_the_page_gives_the_rest() {
    let fake = fake_spotify(true, Some(album_oembed())).await;
    let preview = album_card(&fake).await.unwrap().unwrap();
    assert_eq!(preview.title.as_deref(), Some("Tell Me Nice Things"));
    assert_eq!(
        preview.description.as_deref(),
        Some("Box Fan \u{b7} EP \u{b7} 2026 \u{b7} 5 songs")
    );
    let cover = format!(
        "{}/image/ab67616d0000b273641232778d4254a1bffb3b5f",
        fake.base
    );
    assert_eq!(preview.image, Some(cover));
    assert_eq!(preview.site_name.as_deref(), Some("Spotify"));
    assert_eq!(preview.duration_s, Some(1290));
    assert!(preview.author_name.is_none() && preview.author_url.is_none());
    let media = preview.video.unwrap();
    assert_eq!(media.provider, VideoProvider::Spotify);
    assert_eq!(media.id, ALBUM_ID);
    assert_eq!(media.kind, Some(SpotifyKind::Album));
}

#[tokio::test]
async fn a_show_keeps_its_own_title_over_its_newest_episode() {
    let fake = fake_spotify(true, Some(oembed_titled("#2581 - Protect Our Parks 18"))).await;
    let preview = card(&fake, "show", item(SpotifyKind::Show, SHOW_ID))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(preview.title.as_deref(), Some("The Joe Rogan Experience"));
}

#[tokio::test]
async fn with_oembed_down_the_page_title_is_used() {
    let fake = fake_spotify(true, None).await;
    let preview = album_card(&fake).await.unwrap().unwrap();
    assert_eq!(
        preview.title.as_deref(),
        Some("Listen to Tell Me Nice Things - EP by Box Fan | Spotify")
    );
    assert!(preview.image.is_some());
}

#[tokio::test]
async fn with_the_page_down_oembed_alone_makes_the_card() {
    let fake = fake_spotify(false, Some(album_oembed())).await;
    let preview = album_card(&fake).await.unwrap().unwrap();
    assert_eq!(preview.title.as_deref(), Some("Tell Me Nice Things"));
    assert_eq!(
        preview.image.as_deref(),
        Some("https://image-cdn-ak.spotifycdn.com/image/ab67616d00001e02641232778d4254a1bffb3b5f")
    );
    assert!(preview.description.is_none() && preview.duration_s.is_none());
    assert_eq!(preview.video.unwrap().kind, Some(SpotifyKind::Album));
}

#[tokio::test]
async fn with_both_down_there_is_no_preview() {
    let fake = fake_spotify(false, None).await;
    assert_eq!(album_card(&fake).await.err(), Some(FetchError::Unavailable));
}

#[tokio::test]
async fn a_page_that_redirects_somewhere_refused_refuses_the_card() {
    let fake = fake_spotify(true, Some(album_oembed())).await;
    let refused = card(&fake, "to-ftp", item(SpotifyKind::Album, ALBUM_ID)).await;
    assert_eq!(refused.err(), Some(FetchError::Refused));
}

#[tokio::test]
async fn a_short_link_that_lands_on_no_item_previews_the_page_and_asks_oembed_nothing() {
    let fake = fake_spotify(true, Some(album_oembed())).await;
    let short = format!("{}/album", fake.base);
    let oembed = format!("{}/oembed", fake.base);
    let preview = short_link_preview(&build_client(true), &short, &oembed, true).await;
    assert!(matches!(preview, Ok(Some(_))), "{preview:?}");
    assert_eq!(fake.oembed_hits.load(Ordering::Relaxed), 0);
}
