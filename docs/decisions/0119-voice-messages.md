<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0119 - Voice messages, with optional transcripts from the speech listener

Status: accepted, 2026-11-13.
Builds on [0113](0113-call-transcripts.md) and `docs/research/voice-messages-plan.md`.

## Decision

A voice message is an ordinary audio attachment recorded in the composer and marked at upload with its length and a 64 bucket waveform.
The marks live in a side table keyed by the blob, so a message read carries them without a new column on any hot table.

Transcripts are made by the speech listener that already transcribes calls, not by a second engine in the server.
The listener gains `POST /v1/transcribe`, which takes WAV or Ogg Opus bytes under the same bearer secret, decodes them in memory to 16 kHz mono, and runs them through the engine pool the calls use.
The server never decodes audio and its image gains nothing: a background worker beside the attachment text pass sends the stored bytes and writes the answer back.

## Why not the plan's whisper-cli in the server image

The server image has no ffmpeg, and a second model and binary would duplicate what the listener already ships and keeps checked.
A Space with no listener cannot turn the setting on (409), and reads it as unavailable, the same as call transcription.

## Recording format by platform

The `record` package writes Opus in Ogg on Android and Linux (Linux needs ffmpeg on the machine, and falls back to WAV without it).
Apple writes Opus only in a CAF container that nothing else plays, and Windows and the web have no Opus encoder, so those record 16 kHz mono WAV.
Both sniff as audio on the server, and the listener reads both.
A five minute WAV is about 10 MB, which stays under the attachment limits.

## Privacy and lifetime

- Audio never leaves the deployment.
- Encrypted messages are never offered to the worker.
- A transcript is a row per blob with a cascade, and its words are indexed in `attachment_text_fts`, so it follows message delete and retention and is found by search.
- Turning the setting off stops new work and hides transcripts from readers; they are kept until the message goes.
- A `message.voice_transcript` frame, ephemeral and lossy, tells readers when a transcript starts, finishes or fails; reading the message is the catch-up.

## Not in this phase

Search results saying "matched in transcript", a per-Space daily cap, and a button to delete transcripts while keeping the messages.
