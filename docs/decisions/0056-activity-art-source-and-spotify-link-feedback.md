# 0056 - activity carries a source label and Spotify cover art, and linking says what happened

Status: accepted, 2026-10-01.
Amends [0044](0044-rich-presence.md), which said art would never be a sender-supplied URL.

## The report

The owner, on the live deployment, across three backlog messages and his answers:

> "show what I'm playing on Spotify on phone opens browser to do functionality, can it just open the app where I'm already logged in?"
> "i click agree, it flips me back to the app but nothing happens"
> "I guess there is just no visual confirmation? ... after I press agree anything happens, the tab doesn't close, and I don't feel like I integrated with Spotify, the one way I got the playing working was the native media player listener"
> "listening box ... this is technically a youtube video not my spotify music currently playing"
> "album covers from Spotify songs would be nice but ... not sure if the integration was working or if that was from native media listener"

## What was found

- The redirect `slimm://spotify-callback?code&state` reached the router as well as the deep-link stream.
  go_router read the empty path as `/`, so the open Settings modal was replaced by the channels screen and nothing said the link had finished.
  `spotify_callback_route_test.dart` reproduces this through Flutter's `pushRouteInformation` channel.
- The only record of a link attempt lived in a future held by the process.
  If the OS killed the app while the browser was open, the redirect had nothing to finish.
- Any error that was not a Spotify, timeout or client exception (a bad JSON reply) left `link()` with an unhandled exception.
- There is no Android or iOS now-playing listener in this repo.
  On a phone the Spotify link is the only source.
  The "native media player listener" that worked is the Linux MPRIS source (or Windows SMTC), which reads browsers too.

## Decision: link feedback

- A pending link (verifier, state, start time) is stored in the key store, so the redirect completes it even after a cold start.
- The deep-link controller owns the redirect: it consumes it, never routes it, and a small `WidgetsBindingObserver` registered before the router swallows the matching route information so Settings stays open.
- Settings shows the state in place under the Spotify switch: waiting (with Cancel), connecting, `Connected as <name>` (with Disconnect), or a persistent `AppErrorState` with Retry.
- Every redirect outcome has a message: success, consent denied, state mismatch or expired, nothing pending while linked (ignored), nothing pending while not linked (expired), a refused or unreadable token reply, an unreachable network.
  The `error` text in the URL is never shown, since any app can open that link.
- After a redirect that arrives while Settings is not open (a cold start), the app opens the Profile pane so the result is visible.
- The name is `display_name` from `GET /v1/me`, which needs no extra scope.
  If that call fails the row says `Connected to Spotify`.
- The browser tab staying open is out of our hands: the page after "Agree" is Spotify's, and a custom-scheme redirect hands control to the app without closing the tab.
  Nothing on that page can be changed without a redirect page we host, which would add a server hop for a cosmetic gain.

## Decision: app-to-app login, not built

Spotify documents app-switch authorization only through its Android and iOS SDKs, which are a native dependency and a different flow from the PKCE one 0044 chose.
Whether `accounts.spotify.com/authorize` opens the installed Spotify app from a browser intent depends on the device and the app's link claims, and could not be verified without a phone.
So it is not built.
Steps for the owner to test on a real phone, with the build that has a client id:

1. Install the Spotify app, sign in, then turn the Spotify switch on in slim-m.
2. Note whether the consent page opens in the Spotify app, in a browser that is already signed in, or asks for a password.
3. Tap Agree and note whether slim-m comes forward and the row reads `Connected as <your name>`.
4. If the browser asks for a password every time, the next step is an in-app auth session (`ASWebAuthenticationSession`, Custom Tabs), which shares the browser's login and is a plugin, not the Spotify SDK.

## Decision: source label and art on the wire

Two optional fields on `PresenceActivity`, additive:

- `source`: at most 32 characters, never empty, the shared hidden-character check.
  MPRIS fills it with the player's `Identity` ("Spotify", "Mozilla Firefox"), the Spotify link with "Spotify".
  Viewers read "Listening on Firefox" instead of mistaking a video for Spotify.
  The device's own Settings line also says which feed is sending: the Spotify link or this computer's player.
- `art_url`: accepted only as `https://i.scdn.co/image/` followed by exactly 40 lowercase hex characters.
  No other host, port, userinfo, query or fragment, and the server refuses anything else with 400 rather than dropping it.

Why a URL at all, when 0044 refused one: the risk was a sender making other clients (or the server) request an arbitrary address.
An exact pattern on one CDN host removes that: the server never fetches it, and a viewer's client only ever contacts Spotify's image CDN.
The client applies the same rule before drawing, so an old or hostile server cannot widen it.
The remaining cost is that a viewer's IP address reaches Spotify's CDN when they open a card showing Spotify art.
That is accepted because the sender chose to share a Spotify track, and nothing is proxied or stored.
Art from any other source (a browser video thumbnail, a local file URL) never leaves the device: the sender drops it and the card shows a placeholder.
Adding a host later is one edit to `is_allowed_art_url` plus its client twin and this record.

Spotify's `currently-playing` reply already carries `item.album.images`, so no scope changes: still `user-read-currently-playing`.
MPRIS `mpris:artUrl` is passed through only when it satisfies the same rule, which is what Spotify's desktop app reports.
Windows SMTC and the macOS source are unchanged; their art and player name are not read.

Everything stays off by default, and appear-offline still stops both feeds from opening and the server from announcing.

## Addendum, 2026-11-19: Windows

A Windows user reported that linking was "stuck on the agree page".
Reproduced in the win11 VM on the 0.131.0 setup install, three separate causes:

- Only the setup registered `slimm://`.
  A zip copy, `install.cmd` and a copy moved in from Settings > About had no handler, and Edge drops a redirect to an unregistered scheme with no prompt, so the page stays on Agree.
  Every copy now registers the scheme when it starts (`link_scheme.cpp`), pointing at the launcher from the per-user layout and at itself otherwise.
- A second launch handed its link over through app_links, which only accepts a running copy at the same exe path.
  When the launcher started a newer `app-<version>` folder than the running copy, the link was lost.
  The runner now matches the running copy by file name and sends the link on its own channel.
- With the scheme working, the token exchange failed with `CERTIFICATE_VERIFY_FAILED` and Settings said Spotify sent a reply the app could not read.
  `accounts.spotify.com` chains to Starfield Root G2, which a fresh Windows does not store: Windows downloads such roots the first time its own TLS stack needs one.
  Dart reads only the roots already stored, and Edge verifies with its own root store, so signing in there never installs it.
  On Windows the Spotify client now opens the host once through WinHTTP when that happens, which lets Windows fetch the root, then retries over a fresh `SecurityContext`.
  Other hosts the app reaches from Dart can meet the same gap; `RootFetchingClient` is the tool if one does.

Edge's "This site is trying to open slim-m" prompt has Cancel as its default button.
Settings does not mention the prompt yet.
