# Listen along (plan)

Owner request, 2026-11-07: "Spotify listening parties? or jams or something to where people in voice call can listen to music together, listen along or something? big feat plan it out", pointing at Discord's "Listening Along with Spotify".
Owner choice: Spotify follow plus a call party; followers need Spotify Premium.

## What Discord does

A member who links Spotify shows "Listening to Spotify" with the track.
Anyone can press "Listen Along" on that status; their own Spotify app then plays the same track at the same position and keeps following the host until either side stops.
The host sees who is listening.
Playback stays in each person's own Spotify, so nothing is streamed through Discord and each listener needs Premium (Spotify only allows remote control of Premium accounts).

## What slim-m already has

- Spotify linking with PKCE, tokens kept on the device (`client/packages/app/lib/src/spotify/`), scope `user-read-currently-playing` only.
- The "Show my Spotify track" activity feed (`features/members/providers/activity_feeds.dart`), published as presence with title, artist, art and `ActivityProgress` (position, duration, sampled at).
- Presence fan-out over the WebSocket, so every member already sees the track and its position live.

What is missing: the track's identity (presence has no Spotify URI), permission to control the listener's player, and the follow loop.

## Design

### 1. Host side

- Add the track URI and an `is_playing` flag to the Spotify activity (`spotify:track:<id>`), as optional fields on `PresenceActivity`.
  The server stores and relays them opaquely, the same as `art_url`; it must validate the URI shape (`spotify:track:[A-Za-z0-9]{22}`) so presence cannot carry arbitrary strings.
- Publish a fresh sample on every track change, pause/resume and seek (the poller already samples position; a seek shows as a position jump beyond drift).
- A host can turn "Let people listen along" off in the activity settings; the field is then left out and no Listen Along button shows.

### 2. Listener side (follow loop)

- Widen the Spotify scope with `user-modify-playback-state` and `user-read-playback-state`.
  Existing links keep working for status; Listen Along asks to re-link once when the scope is missing.
- Pressing Listen Along starts a client-side follower:
  - `PUT /v1/me/player/play` with the host's track URI and the host's position extrapolated to now (`positionMs + (now - sampledAt)`).
  - On each host presence update: a new track or a drift past ~3 s re-sends play at the corrected position; a pause pauses; a resume plays.
  - The follower stops when the host stops sharing, leaves, or the listener plays something else themselves (read playback state and compare the track).
- No active Spotify device: show "Open Spotify on a device first" with a button that launches the app (the existing `spotify_launch.dart`), then retry.
- Not Premium (the API answers 403 `PREMIUM_REQUIRED`): say so once and stop.

### 3. Who is listening

- The listener publishes a small `listening_along: <hostUserId>` field in its own presence while following.
  The host's profile card and the member row show "N listening along" with their avatars.
- The cap is 20 listeners per host, enforced client-side by hiding the button, like Discord's party size.

### 4. In a voice call (the party)

- The call dock gets a music-note control when anyone in the call shares a Spotify track: "Listen along with Riley".
  One press joins; the control shows the track, the host and the listener avatars, and a Leave.
- Starting a party from the dock just means "share my Spotify and invite the call": it turns on the host's sharing for the call and posts a call notice ("Nick started a listening party") using the existing voice-activity notices (decision 0107).
- The call never carries the music; everyone's own Spotify plays it, so call audio and bandwidth are unchanged.
  Ducking: optional, out of scope for v1.

## Server work

- Additive presence fields (`track_uri`, `is_playing`, `listening_along`), validated, documented in `schema/openapi.yaml`.
- No new routes, no storage beyond presence (presence is not persisted).

## Client work

- `spotify_config.dart` scope and a re-link prompt.
- `spotify_client.dart`: play, pause and seek, plus a playback-state read.
- A `ListenAlongController` (Riverpod) owning the follow loop, keyed by host, with a fake Spotify client for tests.
- UI: the Listen Along button on profile cards and member rows, the call dock control, and a "listening along" indicator for the host.

## Risks and open questions

- A Spotify app in development mode allows only 25 allow-listed users; a wider rollout needs Spotify's extended quota review.
  This applies to the existing status feature too.
- Spotify's Web API has been narrowed over time; play, pause and seek on the user's own player are still available to Premium accounts, but this should be re-checked against the current terms before building.
- Drift is up to about a second on each correction; that is acceptable for listening along, not for exact sync.
- Phones: iOS backgrounds the app, so the follow loop pauses while slim-m is suspended; Spotify keeps playing the current track, and the loop catches up on return.

## Tests

- Follow loop against a fake Spotify client: track change, seek, pause and resume, host stops, listener overrides, 403 Premium, 404 no device.
- Presence validation on the server: a bad URI is refused, the fields round-trip.
- Widget tests for the dock control and profile button, with rebuild counts kept flat (see the 2026-11-07 perf rule in `docs/design/design-language.md`).
