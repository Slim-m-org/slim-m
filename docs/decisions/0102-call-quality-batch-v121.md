# 0102 - Call quality batch (v121)

Status: accepted
Date: 2026-11-02
Extends: 0047 (the call dock), 0008 (space analytics)

## Why this exists

The owner reported voice quality problems in real calls: swallowing, chewing and background noise getting through louder than normal even with strong suppression on.
A source and measurement audit followed ([voice-stream-audit-2026-11-02.md](../research/voice-stream-audit-2026-11-02.md)), and v121 ships the fixes it supported.
This record keeps the owner's answers to the audit's open questions (its section 9.3), so a later change does not reopen them by accident.

## Decisions

1. **Strong noise suppression stays off by default.**
   The Space flag is not flipped until Strong has been validated with real voices and the owner is happy with it.
   Too many oddities remain in voice calls to call it functioning or beneficial yet.
   Strong stays opt-in per person, and the Space default keeps resolving to Standard.
   Audit item A1.
2. **Data saver maps screen shares to the small layer.**
   A viewer on Data saver requests the low simulcast layer of a share when the tile is not enlarged, instead of the same layer as Balanced.
   An enlarged tile keeps the high layer, and no third simulcast layer is added.
   Audit item S3.
3. **Stereo share audio is deferred.**
   Shared audio stays mono on the wire.
   Making it stereo needs a patched or forked `livekit_client` for the stereo feature flag, and the benefit is small next to that cost.
   It is tracked on the board, not built.
   Audit item S5.
4. **A diagnostics export comes before any server-side quality record.**
   The first step is a one-tap copy of call diagnostics in Settings, Troubleshooting, so Windows and iPhone friends can send real data.
   A server-side record stays off the table until that export proves it is not enough.
   If one is ever built it follows 0008: an opt-in Space toggle, anonymous aggregates only, gated by the manage-server permission, never a row per user per call.
   Audit item M5.
5. **Phones get a visible share-options entry.**
   Share resolution and frame rate are no longer reachable only by long-press on the share button.
   This amends 0047, whose width budget (293 of 336 at 360 wide) was the reason for hiding it, and the entry must fit inside that budget or give up a different control the same width.
   Layout follows width, never platform (`docs/design/desktop-vs-mobile.md`).
   Audit section 6, item 1.
6. **Reconnect is display only.**
   The call shows when LiveKit is reconnecting, resuming or restarting ICE, with a short debounce.
   No new recovery layer is added, because the SDK already recovers and the audit found no failure that a second layer would fix.
   Audit item R1.
7. **LiveKit moves to 1.13.11, after staging.**
   The move is pinned by digest and happens in a maintenance window with the previous digest ready for rollback.
   Staging first covers a relay-only join, a Windows and an iPhone join and resume on the current client, and the e2e quality and share matrix against both versions.
   The change in TURN behaviour between 1.10 and 1.13 is the reason it is not done blind.
   Audit item N3.

## What this does not decide

- Text shares keep `balanced` degradation for now (audit item S4).
  Any split by content type waits for the share matrix under CPU and uplink caps.
- The audit's other deferred items are cards on the Planka board, each with its own proof step.
- No visual token changed, so `docs/design/design-language.md` is untouched.
