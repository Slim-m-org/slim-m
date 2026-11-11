# 0115 - the game a member plays comes from their linked Steam account, not from the machine

Status: accepted, 2026-11-11.
Amends [0044](0044-rich-presence.md) and [0056](0056-activity-art-source-and-spotify-link-feedback.md): local game detection is removed.

## Decision

The owner, 2026-11-11: link Steam only, and delete local game detection.

- The client no longer looks at running processes, Steam's registry keys or install manifests, and the hardcoded game allowlist is gone.
  Spotify and the OS media session are untouched.
- Linking Steam is optional and off by default.
  Each member links it in Settings, and a separate "Share what I'm playing" switch, also off by default, says whether the game shows.
  Hidden or appear-offline still hides it, through the same `status_for` choke point as every other activity.
- Game art is the Steam store header image.
  A game with no art, or no Steam id, shows a plain game icon (Lucide `gamepad-2`).
- The member card and profile popover show a Play button when the activity carries `steam_app_id`.
  It opens `steam://run/<id>`; Steam shows the store page when the viewer does not own the game.

## How it works

- **Link.** Steam's OpenID 2.0 sign-in.
  `POST /me/links/steam/start` returns the `steamcommunity.com` login URL, with a one-time state in the return address.
  `GET /links/steam/callback` spends the state, then trusts nothing in the response until it checks the return address is ours, the claimed identity is `https://steamcommunity.com/openid/id/<17 digits>`, and Steam answers `is_valid:true` to a `check_authentication` POST of the same parameters.
  It then holds the SteamID64 under the existing handoff code, and the member's own app finishes with `POST /me/links/steam/complete`, exactly as for Discord.
  The `linked_accounts` row has provider `steam`; migration 0185 widens the provider checks and adds `share_activity`.
- **Config.** `SLIMM_STEAM_API_KEY` and `SLIMM_STEAM_REDIRECT_URI` (this server's public `/links/steam/callback`).
  Either missing means the feature is off: the start route answers 501 and `/version` says `steam_link_enabled: false`, so the client hides the row.
- **Poller.** Every 30 seconds the server asks `GetPlayerSummaries` (batches of 100) about members who linked Steam, switched sharing on, are connected and are not hidden; nobody else is looked up.
  A running game becomes a `playing` activity with source `steam`, `started_at` from when the server first saw that game, the header image and `steam_app_id`.
  No game clears a Steam activity, and never one from another source.
  A 429, a 5xx or any failed call keeps the last state and doubles the wait, up to five minutes.
- **Art.** `store.steampowered.com/api/appdetails` is asked once per app and cached in memory; a miss is remembered for an hour.
  The stored URL has its cache-busting query dropped.
  `is_allowed_art_url` now also accepts an https path on a `*.steamstatic.com` host with no port, userinfo, query or fragment.
- **Trust.** Only the server may set source `steam` or `steam_app_id`.
  A client PUT carrying either, or Steam art, is refused with 400.
  A game the poller is showing is not replaced by a client's Spotify PUT, because the game is what the member is doing; the track returns when the game ends.

## Not known

- Whether a private Steam profile hides `gameid` from the Web API.
  Steam documents that a profile's game details follow its privacy setting, so such a member probably shows nothing, but this was not checked against a real account.
- The 30 second cadence and the rate Steam allows a single key were not measured.
