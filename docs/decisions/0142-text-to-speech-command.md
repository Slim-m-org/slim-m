<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0142 - `/tts`: the listener speaks a line into the call with Piper, and the text goes to the chat

Status: accepted
Date: 2026-11-26
Extends: 0105 (the listener and its optional deployment), 0118 (a call-wide action that is limited per caller)
Keeps: 0066 (core stores no audio)

## The ask

The owner, on the card "Add a /tts command that speaks a message into the call": "/tts command that lets me talk through a command instead of using my voice".
His answer on 2026-11-26: the server speaks with a small open-source voice (Piper), the audio plays into the call as the person who typed it, and the text is also posted to the call chat.
This replaces the card's recommendation of speech made on each listener's device.

## What exists today

Checked against `origin/main` at 2c331a075.

- The server never touches media.
  It mints LiveKit tokens, calls the room service over HTTP and learns who is in a call from webhooks (0032, 0105).
- The one service that does touch media is the optional listener (`crates/slimm-listener`, 0105): its own Cargo workspace on glibc, because libwebrtc ships prebuilt for glibc only, with the LiveKit Rust SDK, whisper.cpp and a bearer-protected HTTP surface (`/v1/control`, `/v1/transcribe`, `/healthz`).
  The server already has the address and secret (`SLIMM_LISTENER_URL`, `SLIMM_LISTENER_SECRET`) and calls `/v1/transcribe` for voice messages.
- Bots join calls as participants with the Python LiveKit SDK (`slim-bots`, `slimbots/voice.py`), each with its own identity.
- The soundboard (0118) is a signal: every client plays its own cached copy, nothing is published.
  That shape cannot carry synthesised speech, because the text is the only thing that is shared and every device would need its own voice; the owner asked for one consistent voice.
- A LiveKit participant's identity is the member's user id (`voice/mod.rs::mint`).
  LiveKit allows one connection per identity, so a second connection under the same identity would evict the person's own.

## Decision in short

- **Where Piper runs:** in the listener, as a subprocess it starts per line.
  Not in the server and not as a new container.
- **How audio reaches the call:** the listener joins the room for the length of one line as a visible participant, publishes a microphone track and leaves.
  The participant is named "<display name> (TTS)", with identity `tts-<user id>`.
- **How it is asked:** `POST /channels/{id}/voice/tts` on the server queues the line; the server calls the listener's `POST /v1/speak` with a token it minted, the same way it calls `/v1/transcribe`.
- **The text in the chat:** the client posts it as an ordinary message once the route accepted the line.
- **Off when absent:** a deployment without the listener, or with a listener that has no voice, answers 501 and the client says so.

## Where Piper runs

| Option | Verdict | Why |
| --- | --- | --- |
| Inside the server image | Declined | The server is one static musl binary on distroless, and the gate in `server-ci.yml` fails the image past 30 MiB. Piper is a native phonemizer, onnxruntime and espeak-ng data: a 26 MB download that unpacks to 52 MB, plus a 63 MB voice. It does not link into musl, and a child process in the server image would add 115 MB for a feature most self-hosts never use. Measuring the musl build (see the note on measuring the shipped build) is moot: nothing of Piper runs in that binary. |
| A sidecar container of its own | Declined | It would need its own image, secret and URL, and still needs something that can join LiveKit to publish. That something is the listener. |
| In the listener | **Chosen** | The listener is already the optional, glibc, media-capable service with a secret and a health check. Adding Piper to it is one more binary and one more voice file, in an image that already carries whisper's 148 MB model. A deployment that does not run the listener pays nothing. |

Piper is the standalone release build (`rhasspy/piper` 2023.11.14-2, MIT), pinned by sha256 per architecture in `docker/listener.Dockerfile`, with the voice `en_US-lessac-medium` pinned to a commit of `rhasspy/piper-voices` and checked against its sha256.
The voice is fetched once on first start into the existing `listener_models` volume, the same way the whisper model is, and a failed fetch leaves text to speech off instead of stopping the listener.
`PIPER_MODEL` empty turns it off; another `.onnx` (its `.json` beside it) swaps the voice.
Language is a property of the voice, so a deployment that wants another language picks another voice; there is no per-user voice in this decision.

Measured on the dev machine (16 cores) with the pinned release and this voice: a 70-character line synthesises in 0.32 s of wall time and 4.9 s of CPU time, because onnxruntime spreads one line over every core it can see.
That is a burst, not a load, and the listener makes at most two lines at once; the container's `cpus: 4.0` limit bounds it.
The real-LiveKit test line (2.3 s of speech) reached a second participant as 2.07 s of audio.

## How audio reaches the call

Publishing "as the invoker" is not possible: LiveKit keeps one connection per identity, so a second connection under the member's user id would drop their own.
Instead the listener joins as a second participant.

- **Identity:** `tts-<user id>`.
  It never parses as a user id, so the webhook and roster paths skip it (as they do for `listener-<session>`), and it appears in no member list.
  Having the invoker's id inside the identity lets a client draw the speaking tile with the invoker's avatar (`VoiceParticipant.userId`).
- **Name:** "<display name> (TTS)", set in the token, so it can never pass for the person.
- **Grants:** `canPublish` only: `canSubscribe`, data and metadata updates are off, and it is not hidden, because a hidden participant cannot publish and everyone should see who is speaking.
- **Track:** a microphone track, so clients play it through the same path as a voice: per-person volume, deafen and the output device apply.
  The listener resamples Piper's output (22.05 kHz for the default voice) to 48 kHz, sends it in real time in 10 ms frames, adds 400 ms of silence so the receiver plays the last word out, and leaves.
- **Token:** minted when the line's turn comes, not when it was typed, with the normal 120 second TTL, so a queued line never holds an expired one.
- **The listener's side:** `POST /v1/speak` with the bearer secret takes `{livekit_url, token, text}`.
  It replies 204 once the line has been played, 422 for an empty or over-long line or speech over 30 s, 501 with no voice, 502 when the room refused, 500 when synthesis failed.
  `GET /v1/speak` answers 204 or 501 so the server can tell "not set up" before accepting a line.
  Two lines at most are made at once across all calls, which bounds the CPU Piper takes.

## Limits

| Limit | Value | Where |
| --- | --- | --- |
| Length of a line | 300 characters, after collapsing whitespace to single spaces | server (400) and listener (422) |
| Length of the speech | 30 seconds | listener (422) |
| Per person | 2 lines at once, then one every 5 seconds (`Class::Tts`, 429 with `retry_after_seconds`) | server rate limiter |
| Queue per call | 5 lines waiting or being spoken, at most 2 of them one person's | server (429) |
| Order | one line at a time per call, first in first out | server queue |

The five-second refill is longer than the soundboard's three seconds because a line is up to twenty seconds of one voice in everyone's ears, where a clip is at most five.

A line whose speaker has left the call by its turn is dropped, so a queue never speaks for someone who is gone.
A listener that cannot be reached or has no voice marks speech unavailable for 30 seconds; the next line is then refused at once with 501 instead of waiting out a timeout.
Failures after a line was accepted (the room refused, synthesis failed) are logged on the server and nothing is spoken; the text still reaches the chat.

## Permissions and the guards

`POST /channels/{id}/voice/tts` needs, in that channel:

- VIEW_CHANNEL and CONNECT, as for any call route;
- SEND_MESSAGES, because the line is also a chat message;
- SPEAK, because it is the member's voice;
- a seat in the call, read from the room (the webhook roster when trusted, else the SFU), so a watcher outside the call is refused with 403 "join the call to use text to speech";
- the `Participant` hold that every write route honours: a member who has not accepted the rules, or is timed out, is refused.

Server mute is the absence of SPEAK in the channel, which is how the server already stops a muted member's own microphone track: their token carries `canPublish: false` and the grants are pushed when the permission changes.
So a server-muted member's `/tts` is refused with 403 and nothing is queued.
A member who muted themselves is not refused: the command exists for people who cannot or will not use their microphone.
Blocks and do-not-disturb need nothing here: the speaking participant is an ordinary voice in the call, subject to each listener's own per-person mute and deafen, and DND silences notifications, not a call the listener is in.

## The text in the chat

The route speaks; it does not post.
The client calls the route first and, on 202, sends the text (without `/tts `) through the ordinary send path, so replies, slow mode, retries and every message rule apply to it unchanged.
Refused lines post nothing and the typed command stays in the field with the reason beside it.
The alternative, a server-side post inside the route, would have duplicated the 240-line send handler or needed a new message field on every path (the lesson of per-message data).
The cost is that a client which dies between the two calls speaks a line that is never posted, which is the lesser failure.

## The client

- `/tts <text>` in the composer of the channel whose call you are in: a voice channel, a DM call or a canvas channel's call.
  The autocomplete row appears only while you are connected to that call, as `/gif` appears only with a GIF provider.
  Typed outside the call it says "Join the call in this channel to use /tts." and posts nothing.
- While it speaks, the call stage shows a tile "<name> (TTS)" with the speaking ring and the invoker's avatar, for as long as the line plays.
  That tile is the indicator; there is no extra control.
- Errors use the composer's inline error band, never a SnackBar: not set up (501), over the rate (429), not allowed in this call (403), an older server without the route (404).
- Layout does not differ between desktop and mobile: this is composer text, so `docs/design/desktop-vs-mobile.md` rule 1 (the same surface at every width) applies and nothing branches on width.

## Alternatives considered

- **On each listener's device, from a call event (the card's recommendation).**
  Cheap and private, but the voice differs per device and platform, some devices have none, and the owner asked for one voice.
  Declined.
- **On the sender's device, injected into their microphone track.**
  Piper does not run on phones or the web build, and mixing into the capture path touches the noise gate and echo handling for every call.
  Declined.
- **Under the invoker's own identity.**
  Not possible, as above.
- **A new client-visible event for "speaking" and failures.**
  A private websocket frame per line would add a frame type, a hub event and a client handler for what the participant tile already shows.
  Left out; it can be added if failures after acceptance prove common.

## Consequences

- The listener image grows by about 52 MB and its first start downloads 63 MB more.
  A deployment without the listener is unchanged.
- The server image is unchanged.
- A call briefly shows a participant the server's roster does not list.
  The client's roster-gap check only looks for people the server lists and the call does not show, so an extra participant is harmless to it.
  The speech tile's menu offers the volume and mute-for-me controls like any voice, and no profile actions, because the identity is not a member.
- `tests/real_tts.rs` in the listener plays a line through real Piper into a development `livekit-server` and checks another participant hears it; it is opt-in like `real_livekit.rs`.

## Not decided here

- Per-person voice choice, and more than one voice per deployment.
- Speaking in languages other than the voice's.
- Showing a failure after acceptance to the person who typed it.
