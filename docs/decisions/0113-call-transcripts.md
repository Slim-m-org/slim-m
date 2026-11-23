# 0113 - Call transcripts are part of the call, kept by the server

Status: accepted, 2026-11-11; amended 2026-11-16 (see the end).
Amends 0105 (call audio) and 0066 (call history).

## The ask

The owner, after seeing the Call transcript module: "i dont like the way transcripts are handled, i'd like them to be integrated with voice call not just spammed in a chat, in my head itd be like an artifact of a call and perhaps searchable and indexed by ctrl k search and useful for data analytics later".

Owner's answers on 2026-11-11:
- Built into the server, not a module.
- Who can read: "anyone at anytime in the future if its enabled and they have permissions".
- Retention: "configurable retention like messages".
- Starting: "space level setting, they just get recorded by default, per call, or off".

## Decision in short

Transcription becomes a core voice feature.
The server keeps each transcribed line (speaker, time, text) as part of the call it happened in.
The idle voice pane shows a call's transcript next to "What happened", Ctrl+K search finds lines, and the rows are structured so analytics can read them later.
The `transcript` module in slim-addons is retired; the `call.audio` module capability stays for other modules.

This reverses 0105's "What core keeps: nothing that outlives the process" for transcripts only.
Module sessions still never write segment text to the database.

## Space setting: transcription mode

`call_transcription` on the Space: `off` (default), `on_request`, `always`.

- `off`: nothing is transcribed by the server. Modules with `call.audio` work as 0105 describes.
- `on_request`: the 0105 per-call flow, with the server as the consumer. Someone in the call presses Transcribe, everyone is asked, it runs only while everyone in the call agrees; a joiner is excluded until they say yes.
- `always`: every call in every voice channel is transcribed from its first join. Nobody is asked per call. The first time a member joins a call while the Space is `always`, they get a one-time notice ("Calls in this Space are transcribed") that they acknowledge before joining; the acknowledgement is stored on the server per member (`transcription_notice_ack_at`), so it is shown once across devices and never on later calls. The in-call banner still says transcription is on, as a passive indicator. Bots are never heard (0105 rule 6).
  Owner, 2026-11-11: "we can still first time inform them, just not every voice call they join".

The listener must be configured (`SLIMM_LISTENER_*`); without it the setting is shown disabled with the reason.
Changing the mode is an admin change and is audited.
At most one session per call (0105 phase 1): while the server transcribes a call, a module cannot start a `call.audio` session in it, and the reverse.

## What is kept

- `call_transcripts`: one row per transcription session. `id` (UUIDv7), `channel_id`, `started_at`, `ended_at` (null while running), `mode` (`on_request`|`always`), `started_by` (null for `always`).
- `call_transcript_lines`: `transcript_id`, `seq` (per transcript), `speaker_id`, `at` (ms, segment start), `text`.
- An FTS5 index over line text, the same tokenizer and trigger shape as message search.
- Speaker display names are not copied; the client resolves ids like everywhere else.

A transcript belongs to the call whose span (0066) contains its `started_at` in the same channel.
`GET /channels/{id}/voice/calls` adds an optional `transcript_id` to each call that has one (additive).

## Who can read

A new permission bit `VIEW_TRANSCRIPTS` (`1 << 20`), granted to `@everyone` by default and deniable per role or channel like any other.
Reading a transcript, or getting it in search, needs `VIEW_CHANNEL` and `VIEW_TRANSCRIPTS` on its channel at read time.
It does not matter whether the reader was in the call.
Someone whose presence is hidden is still transcribed and named in the lines; 0066's hidden-presence rule applies to the call's timeline, not to what was said.

## Retention and deletion

`call_transcript_retention_days` on the Space, mirroring message retention (null = keep forever, default 30).
A sweep deletes transcripts whose `ended_at` is past it, with their lines and index rows.
`DELETE /voice/transcripts/{id}` needs `MANAGE_MESSAGES` on the channel.

## API (additive)

- `GET /voice/transcripts/{id}?after_seq=&limit=` -> `{id, channel_id, started_at, ended_at, mode, lines: [{seq, speaker_id, at, text}], next_after_seq}`. 404 when the reader lacks the permissions.
- `DELETE /voice/transcripts/{id}`.
- `GET /search/transcripts?q=&before=&limit=` -> hits `{transcript_id, channel_id, seq, speaker_id, at, text, highlight}` across every channel the reader may read, newest first.
- Space settings carry `call_transcription` and `call_transcript_retention_days` through the existing settings route; the space-settings playbook (the memory `adding-a-space-setting-playbook`) is the checklist.
- `GET /voice/transcription-notice` -> `{mode, acknowledged}` for the caller; `POST /voice/transcription-notice/ack` records `transcription_notice_ack_at` for the caller (idempotent).
- Hub events: `CallTranscriptChanged {channel_id, transcript_id, ended}` on start and end, so the idle pane refreshes; lines are not fanned out live in this phase.

## Client

- Space settings, Voice: "Call transcripts" with Off / When someone asks / Always, a retention picker beside it, and the listener-missing reason when it applies.
- In a call: the 0105 banner, worded for the server ("This call is being transcribed"), with Stop in `on_request` and no Stop in `always`. In `always`, the one-time notice before the first join (a modal with "Join" and "Cancel"; Join records the acknowledgement), and nothing on later joins.
- Idle voice pane: a call with a transcript shows a "Transcript" section under "What happened": lines with avatar, name and clock time, collapsed to the first lines with "Show all", plus Delete for those allowed.
- Ctrl+K: transcript hits are a result group; choosing one opens the voice channel's idle pane on that call, scrolled to the line.

## Data export and analytics

A member's export includes the lines they spoke (`transcript_lines.jsonl`).
Analytics reads the tables directly later; nothing analytic is built in this phase.

## Not in this phase

Live transcript while the call runs, per-channel modes, summaries, and exporting a transcript as a file.

## Amendment 2026-11-16: live lines, end time and language

Each line now also keeps `end_at` (ms, segment end) and `language` (a lowercase tag such as `en`, as the listener heard it).
The listener already sent both, so nothing new is collected; lines kept before migration 0195 have them null.
The read routes, search hits and the member export carry them (additive).

Lines are now sent live, as `call.transcript_line {channel_id, transcript_id, line}`, the moment the server keeps them.
A line reaches only the people in the call at that moment (the server's in-memory call roster) who hold `VIEW_CHANNEL` and `VIEW_TRANSCRIPTS` on the channel.
Hidden presence changes nothing: someone hidden in the call gets the lines, and someone hidden outside it does not.
Someone who left stops getting lines from the next one on.
A bot in the call counts like anyone else: it gets lines only with both permissions, as it could already read the route.
The event is durable, so a reader who falls behind resyncs; a client applies lines by `seq` and reads the transcript route to fill a gap or catch up after a reconnect.

Nothing else changes about who can read.
Anyone with the two permissions can still read the transcript route at any time, in the call or not, as before.
No screen shows lines live in the call yet; captions, summaries and the rest of "Not in this phase" are still to come.

## Amendment 2026-11-12: a mark in the call header, not a banner, in `always`

Since #2405 the call header shows a transcript mark whenever the server is transcribing the call, in both modes, with "This call is being transcribed" on hover.
In `always` there is no in-call banner any more: nothing in it could be answered or stopped, so the mark replaces the passive banner described above.
In `on_request` the banner with Stop stays, beside the mark.

## Amendment 2026-11-22: your own call stats

A member can read numbers about their own speech: talk time, words a minute, filler words and languages (`GET /me/call-stats`, the "Call stats" pane in personal Settings, and one "You talked ..." line in each call's Transcript section).
They are worked out on request, in plain server code, from the caller's own lines that are still kept (those with an `end_at`, in live community channels), and nothing new is stored.
They follow retention, a moderator's delete, channel deletion and account deletion, and nothing leaves the deployment.

The rule is self-only.
The route has no user parameter, and no administrator view, Space-wide view, per-person numbers shown to other readers of a call, module power or bot route exists.
A bot is refused, and an administrator asking gets their own numbers.
A Space with transcription off answers with nothing counted.
With `transcript_id` the call must be readable by the caller as for `GET /voice/transcripts/{id}`, and only the caller's lines in it count.
Filler words are counted on English lines only, and the pane says the transcriber leaves out most ums and uhs.
A listener's segment `end_ms` is now the end of the last voiced frame, not of the silence that closed it, so talk time is not overstated.

## Amendment 2026-11-22: captions and the live pane

The live lines now have screens.
Captions are a per-device choice, off by default, turned on from the call's Captions control or from Voice & video settings.
They sit in a strip of fixed height under the call stage, show only lines said after the strip opened, as "Name: text", and clear 8 seconds after the last line.
While a transcript runs, the voice channel's chat pane (docked, or the compact swapped view) gains a "Chat | Transcript" choice; the Transcript side lists the whole running transcript and follows the newest line.

Both appear only while the server is transcribing the call and the viewer holds `VIEW_CHANNEL` and `VIEW_TRANSCRIPTS` on the channel, the same rule the live lines already follow.
To know which transcript is running without waiting for `call.transcript_changed`, the call-audio state (`GET .../voice/call-audio` and the `voice.call_audio` frame) carries an optional `transcript_id` once the server's own transcript is on (additive; modules never get one).
The consent text's purpose now reads "Writes down what is said in this call and shows it to the people in it."

Marks, notes and spoken commands are not part of this amendment.
