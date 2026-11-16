# 0118 - A soundboard of short clips the Space owns, played locally by each listener

Status: accepted, 2026-11-13.
Reverses the recorded decline in `docs/BACKLOG.md` and `docs/PRODUCT.md`.

## The ask

The owner, 2026-10-18: "Soundboard controls for users".
Asked for again in #feature-requests on 2026-11-13.

The earlier decline said clip storage, call mixing and upload moderation were non-essential against the not-a-clone principle.
The design below removes two of the three costs: nothing is mixed into anyone's microphone, and moderation is the same admin management custom emoji already has.

## Decision in short

The Space owns a small set of short audio clips.
Any member with the new `USE_SOUNDBOARD` permission can play one from the call controls.
Playing sends a signal; every client in that call plays its own cached copy of the clip, exactly once.
Nothing is published to LiveKit and nothing is mixed into the mic.

Owner's answers on 2026-11-13:
- Clips belong to the Space and are managed like custom emoji; there are no personal clips.
- Each client plays the cached clip locally on a call signal.
- Deafen silences it, the player's per-person volume applies, and a new personal "Soundboard sounds" switch turns it off for that listener.
- `USE_SOUNDBOARD` is granted to the default role.
- Limits: 5 seconds, 512 KB, one play per person every 3 seconds, 48 clips per Space.

## Clips

- Storage mirrors custom emoji (decision 0016's shape): a `soundboard_clips` row names a content-addressed `attachments` blob, so storage, dedupe, the storage ceiling and the orphan sweep are the existing ones.
- Management needs `MANAGE_SERVER`, the permission custom emoji use.
  Add, rename and remove are audited (`soundboard.create`, `soundboard.rename`, `soundboard.delete`).
- Names are 1 to 32 characters, trimmed, unique ignoring case.
- Types are mp3 and wav only.
  The server sniffs more audio types, but ogg does not play on iPhone and the owner's targets are Linux, Windows and iPhone, so a clip a listener cannot play is refused at upload.
- Size is checked at upload (512 KB).
- Length is checked server side by reading it from the bytes, with no decoder: a RIFF chunk walk for wav and a frame walk for mp3.
  A file whose length cannot be read is refused, so a clip cannot claim to be shorter than it is.
- A Space holds at most 48 clips, counted inside the write transaction.
- Reading the list and the audio is open to every member.
  Clips are not per channel, for the same reason emoji are not.

## Starter clips

The owner asked for "some default soundboard items for spaces".

- The server ships 12 short CC0 clips (airhorn, ba dum tss, applause, crickets, sad trombone, quack, drumroll, ding, wrong buzzer, whoosh, laugh track, tada) and offers them to the Space once, at startup, so an existing Space and a fresh one both have a working soundboard.
- Each becomes an ordinary Space clip with no uploader: it counts toward the 48, and an admin renames or removes it like any other.
- Migration 0190's `soundboard_starter_offered` ledger records each clip's key when it is offered, so a removed starter clip stays removed and a later release can add one more.
- A clip whose name is already taken, or that would pass 48, is skipped and still recorded, so it never turns up later.
- When the storage ceiling has no room for them, nothing is recorded and the next start tries again.
- They pass the same checks as an upload; a test runs every bundled file through them.
- No audit row is written, because nobody acted.
- Unlike Discord's global default sounds, these are the Space's own clips, which keeps one list, one cap and one management screen.
- Sources and licences are in `crates/slimm-server/src/soundboard/starter/CREDITS.md`.

## Playing

- `POST /channels/{id}/voice/soundboard/{clip}/play` needs `VIEW_CHANNEL`, `CONNECT`, `SPEAK` and `USE_SOUNDBOARD` in the channel, so a channel overwrite can take it away and a listen-only member cannot play, and the caller must be in the call.
- The server lists the call's participants from the SFU and publishes one private `soundboard.played` event per participant.
  A member who is only watching the channel never receives it, and a member who is not in the call cannot trigger it.
- The frame is `{channel_id, clip_id, player_id}`.
  It is ephemeral: unnumbered, never stored, no catch-up.
  A client that is reconnecting misses clips rather than replaying them later.
- The rate limit is one play per person every 3 seconds, a new `Soundboard` class with a burst of 1.
- The client fetches a clip's audio once and keeps it for the session, so a later play is local and immediate.

## Listening

A client plays a clip only when it is in that call, is not deafened, has "Soundboard sounds" on, and has not muted the player.
The player's per-person volume scales the clip and never raises it above the clip's own level.
Clips play through the same quiet, no-focus audio configuration as other interface sounds, so they cannot take the call's audio session.

## Known gap

On iPhone, interface sounds are skipped while a call holds the audio session, because playing one can switch the microphone off or move the call to the speaker (`sound_audio_context.dart`).
Clips follow the same rule, so an iPhone in a call does not hear them until a playback path that coexists with WebRTC's session is verified on a real device.
Playing a clip from an iPhone still works, since the signal goes through the server.

## Permission

`USE_SOUNDBOARD` is bit 21.
Migration 0186 grants it to every existing `@everyone` role, and a fresh deployment's default role carries it.
Hidden participants are still in the call, so they get the signal; the frame names the player, who is already visible to everyone in the room.

## What this does not do

- No personal clips and no per-channel clip sets.
- No clip is mixed into a microphone, so a recording of the call, a transcript or a screen share does not carry a clip.
- No audio decoding on the server.
