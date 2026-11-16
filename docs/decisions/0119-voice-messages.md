<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0119 - Voice messages, with optional transcripts from the speech listener

Status: accepted, 2026-11-13.
Builds on [0113](0113-call-transcripts.md) and `docs/research/voice-messages-plan.md`.

## Decision

A voice message is an ordinary audio attachment recorded in the composer and marked at upload with its length and a 64 bucket waveform.
The marks belong to the message, not the bytes: each uploader's claim keeps what they marked, a send copies it onto that message's attachment link, and a forward copies its original's link.
Attachments are shared by content, so marks keyed by the blob (as first built) let whoever uploaded some bytes first decide how every message carrying them rendered; migration 0194 moved them, 2026-11-16.

Transcripts are made by the speech listener that already transcribes calls, not by a second engine in the server.
The listener gains `POST /v1/transcribe`, which takes WAV or Ogg Opus bytes under the same bearer secret, decodes them in memory to 16 kHz mono, and runs them through the engine pool the calls use.
The server never decodes audio and its image gains nothing: a background worker beside the attachment text pass sends the stored bytes and writes the answer back.

## Why not the plan's whisper-cli in the server image

The server image has no ffmpeg, and a second model and binary would duplicate what the listener already ships and keeps checked.
A Space with no listener cannot turn the setting on (409), and reads it as unavailable, the same as call transcription.

## Recording format

Every platform records 16 kHz mono 16 bit WAV.
Every client plays a voice message through `audioplayers`, and that cannot decode Ogg on Windows or iPhone (the reason hold music ships as MP3 in `docs/dependencies.md`, and soundboard clips refuse ogg in [0118](0118-soundboard.md)).
An Ogg Opus message recorded on Linux or Android would not play for those members, and the server stores bytes as they came and never transcodes.
Apple also writes Opus only in a CAF container nothing else plays, and Windows and the web have no Opus encoder at all.

A five minute WAV is about 9.6 MB.
That is far under the default attachment limit (1 GiB), the listener's 24 MiB body limit and the server's 24 MiB cap on what it sends for a transcript.
An admin who lowers the per-attachment limit below about 10 MB refuses the longest voice messages, the same as any other file that size.
On Linux the `record` package captures with parecord and writes the file with ffmpeg, WAV included, so both programs must be installed.

A smaller format such as AAC in m4a would need a playback check on Linux (GStreamer), Windows and iPhone first, and the web has no AAC encoder.
The listener still reads Ogg Opus, which costs nothing to keep.

## Recording and the call

A recording uses the microphone chosen in Voice settings, wherever a call honours that choice, and the system default once that microphone is unplugged.
On iPhone and Android a recording is refused during a call ("Leave the call to record a voice message."), because the recorder reconfigures the one audio session the call holds: on iPhone it can move the call to the speaker, and on Android stopping it drops a Bluetooth headset.
Playing a voice message on iPhone during a call is refused for the same reason.

## Privacy and lifetime

- Audio never leaves the deployment.
- Encrypted messages are never offered to the worker.
- A transcript is a row per blob with a cascade, and its words are indexed in `attachment_text_fts`, so it follows message delete and retention and is found by search.
  Only a link that is a voice message shows it or is found by it; a plain file with the same bytes never is.
- Turning the setting off stops new work and hides transcripts from readers; they are kept until the message goes.
- A `message.voice_transcript` frame, ephemeral and lossy, tells readers when a transcript starts, finishes or fails; reading the message is the catch-up.

## Not in this phase

Search results saying "matched in transcript", a per-Space daily cap, and a button to delete transcripts while keeping the messages.
