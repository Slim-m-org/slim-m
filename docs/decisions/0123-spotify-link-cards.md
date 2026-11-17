<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0123 - Spotify links preview as the item, with a Play button

Status: accepted
Date: 2026-11-16
Extends [0019](0019-link-unfurling-and-ssrf-defense.md).

## The ask

The owner, with a screenshot of a bare `open.spotify.com/track/...` link and no card under it:

> "no spotify embeds, or perhaps in app playing if possible, where they can click a play button on the embed"

## What was wrong

No Spotify link previewed at all.
A track page is 278 KB, a playlist 515 KB and a show 332 KB, and the page fetch refused any body past 256 KiB instead of reading its start, then cached that as a miss.
The same cap hid GitHub, Wikipedia and most news sites.
0019 already said a preview reads only the head; the fetcher now does: it keeps the first 256 KiB of a longer page and stops at `</head>` once the head alone gives a titled preview.
A page that streams its tags into the body after an empty head (Next.js metadata streaming) keeps reading to the cap, as before.

## Decision: the server names the item

- A pasted `open.spotify.com` link to a track, album, playlist, artist, show or episode is parsed to a kind and a 22-character id, and fetched and cached as `https://open.spotify.com/{kind}/{id}`.
  Every `?si=` share of one item is one fetch and one cache entry, and a sharer's `si` token never goes to Spotify from this server.
- The card is built from the page and Spotify's oEmbed, fetched side by side through the same guarded fetch, so either one alone still makes a card.
  The title comes from oEmbed, since an album's `og:title` reads "Listen to X - EP by Y | Spotify"; a show keeps its page title, because its oEmbed names its newest episode.
  The summary line, the 640 px cover and `music:duration` come from the page.
- A `spotify.link` short link is followed first and oEmbed is asked about the item it lands on, because Spotify's oEmbed stalls for five seconds on the short link itself.
- A Spotify page that names no item (a user profile) previews like any other page.
- The wire change is additive: `video_provider` gains `spotify`, and `LinkPreview` gains `media_kind` and `duration_ms`.
  An older client maps the unknown provider to null and shows the ordinary card.

## Decision: the card follows Spotify's brand rules

- The header is Spotify's icon at 24 px, drawn pure white on a dark theme and pure black on a light one, since the green mark belongs only on pure black or white.
  Spotify asks partner integrations for the full logo (icon and wordmark, at least 70 px wide); the repository only carries the Simple Icons icon, so the card pairs it with the word Spotify until the owner adds the official asset.
- The cover is never cropped and nothing is drawn over it: no play glyph, so a Spotify preview is not a YouTube-style click-to-play thumbnail.
  It is 80 px tall at its own shape (a 16:9 episode cover stays 16:9, square on a phone so the text keeps room), with 4 px corners on a phone and 8 px above, as the guidelines ask.
- Beside it: the name, the summary line (a playlist's free-text description is prefixed "Playlist"), and a Play on Spotify button with the length.
  Tapping the card anywhere else also opens the item, which is the link back the guidelines ask for.
- The layout is the same at every width; the button grows to the touch target under `kCompactWidth`.

## Decision: where Play plays

- On web, Play swaps the row for Spotify's own embed, unaltered, at Spotify's own heights (152 px for a track or episode, 352 px otherwise) with Spotify's own `allow` list.
  The web image's CSP `frame-src` allows `https://open.spotify.com` for it.
- On Linux and Windows, Play opens the `spotify:` URI when an installed Spotify app has registered that scheme, and the web page otherwise.
- On a phone, Play opens the https link as an app link, which the Spotify app claims when it is installed, and the browser otherwise.

## What a viewer should know

- Nothing from Spotify loads until a tap: the card's text and cover come through this server, like every link preview.
- After a tap on web, the embed is Spotify's page and sets Spotify's own cookies.
- A viewer who is not signed in to Spotify in that browser, or whose browser partitions third-party cookies (Safari, Firefox), mostly gets 30-second previews in the embed.
- Playback in the embed stops when the message scrolls out of view or the channel changes.

## Rejected

- Spotify's Web Playback SDK or a native SDK in the app: the Web Playback SDK needs Premium, a native SDK is a dependency per platform, and either runs into Spotify's Developer Policy for playback inside a third-party app.
- A webview to host the embed on desktop and phones: a large dependency for one card, for what the Spotify app already does better.
- Playing the 30-second `og:audio` clip ourselves: it plays Spotify's content outside Spotify's own player, which the Developer Policy restricts, and any later listen-along work meets the same policy.
- Keeping covers longer than the 30-minute preview cache: the Widget Terms allow only temporary caching.

## Owner-only

- The official full Spotify logo asset, if wanted in place of icon and word.
- iPhone and Android behaviour on real devices: whether the app link opens the Spotify app.
- Spotify's Widget Terms ask that the Play button be non-commercial; that holds under PolyForm Noncommercial.
