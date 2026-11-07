# Voice messages and transcripts (plan)

Owner request, 2026-11-07: "voice messages, optional transcript of voice messages without listening to it in space settings".
Owner choice: transcripts run on the server with a self-hosted whisper model, turned on per space.

## What exists

- Attachments upload, sniff and serve through the server (`http/attachments.rs`), with per-channel ATTACH_FILES checks.
- The client plays video with `media_kit` and has `audioplayers`, but nothing records audio for a message or shows an audio attachment specially.
- Attachment text extraction already exists for search (`store/attachment_text.rs`, migration 0152): a background pass reads new attachments and writes `attachment_text_fts`.
  A transcript is the same shape of work and can reuse that pass and its index, so a transcribed voice message is searchable for free.

## Recording (client)

- Hold or tap the mic button in the composer when the field is empty (it swaps with the send button, like most chat apps).
  Tap starts a recording with a timer, a live level and Cancel/Send; on a phone, hold-to-record with slide-to-cancel.
- Record Opus in an Ogg container at 32 kbit/s mono via the `record` package (desktop and mobile), capped at 5 minutes.
- Upload as an ordinary attachment with `voice: true` and `duration_ms` plus a 64-bucket waveform computed on the client, so nothing needs decoding on the server to draw it.

## Playing (client)

- A voice attachment renders as a compact player: play/pause, waveform with the played part filled, duration, and a speed toggle (1x, 1.5x, 2x).
- Playback through `audioplayers` (already a dependency; on Linux it needs GStreamer, see the existing note about building it lazily).
- When a transcript exists, a "Transcript" line under the player expands to the text; while it is being made it says "Transcribing...".

## Transcripts (server)

- A space setting "Transcribe voice messages", off by default, in Space settings next to the other message settings (follow the space-setting playbook: migration, store, route, schema, client binding).
- A transcription worker beside the attachment text pass: it picks voice attachments in spaces with the setting on, runs whisper.cpp, and writes the text to the existing attachment-text index plus a `transcript` field on the attachment DTO.
  - Model: `ggml-base` (about 150 MB, multilingual) by default, `tiny` as an operator option for small hosts.
    Downloaded on first enable into the data dir with a checksum, not baked into the image.
  - Runs as a subprocess (the `whisper-cli` binary shipped in the server image), one job at a time, with a time limit, so a long clip cannot stall the server.
  - Audio is decoded to 16 kHz mono with the ffmpeg already used for media work.
- A WebSocket event updates the message when the transcript lands, so it appears without a reload.
- Turning the setting off stops new work and hides transcripts; existing ones are kept unless an admin chooses "Delete transcripts".

## Privacy

- Audio never leaves the deployment; the model runs on the same host.
- Encrypted DMs (when that lands) never get transcribed: the server cannot read them.
- Transcripts follow the message: deleting the message deletes its transcript, and retention applies to both.

## Work breakdown

1. Client recording and the voice attachment flag, waveform, and player (no server changes beyond two additive attachment fields).
2. Server space setting and the transcription worker, whisper-cli in the image, model download.
3. Client transcript line, live update, search showing "matched in transcript".

## Risks

- whisper on CPU: base is roughly real-time to 3x real-time on a small server; a queue and a per-space daily cap keep a busy space from starving others.
- Image size grows by the whisper binary (a few MB); the model stays outside the image.
- Recording permission prompts on macOS and iOS need Info.plist strings and an App Store review note.

## Tests

- Client: recording state machine (start, cancel, max length), the player against a fake audio backend, waveform rendering at phone and desktop widths.
- Server: the worker against a fake whisper binary (a script that prints a fixed transcript), the setting gate, retention and delete cascades, the search hit through the transcript.
