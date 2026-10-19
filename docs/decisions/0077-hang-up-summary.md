<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0077 - The screen after hanging up

Status: accepted
Date: 2026-10-18

## The ask

The owner asked to improve the voice channel hang-up screen.
The Ready card also noted that calls under five minutes got no recap.

## Cause

Since 0066 a voice channel shows the idle pane after a hang-up, and that pane never showed the call just ended: the history behind it lags the LiveKit webhook.
The shell also skipped its "Call ended" toast on wide layouts, assuming a recap card was on screen, so the person got neither.

## Rule

- After hanging up, the voice channel's idle pane opens with a Call ended card: how long, who was there and who left early, and whether a screen or camera was shared.
  It is the recap card the DM pane already used, built from the live roster, nothing new on the server.
- The join button below it says Rejoin (still muted) instead of Join, until the next join clears the recap.
- A call needs 30 seconds to be summarised, down from five minutes, so a mis-click shows nothing and a short real call does.
- Layout follows `desktop-vs-mobile.md`: the card is page content (rule 6 and 7 do not apply, nothing demands a decision), width decides, and the phone keeps its existing return to the last text channel with the toast, which now names who was there.
  Visiting the channel later shows the same card until the next join.
