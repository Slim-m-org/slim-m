<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0097 - One people panel for the call, following and summoning

Status: accepted
Date: 2026-10-28
Amends [0086](0086-avatar-tiles-leave-the-board.md).

## The ask

The owner, 2026-10-23: the Follow people control and the In this call list are two things, and Figma has one list of people in the file with a follow action on each.

## Decision

- The avatar pill in the top-left cluster opens one list, "People here".
  It lists everyone in the call and everyone with a cursor on the board, this device first, then speakers.
  A wide pane anchors it as a popover and a pane under `kCompactWidth` opens a sheet ([desktop-vs-mobile](../design/desktop-vs-mobile.md) rule 3).
- Each row has the avatar, the name, the state in words and a follow toggle.
  A person in the call keeps the menu their call tile has on the row itself.
- "Bring everyone to me" is the one place to summon.
  It asks first and is absent in the personal view.
- Following draws an outline around the view and a ring around the avatar, both in the followed person's cursor colour, and a chip at the top centre that names them and stops the follow.
  The chip shares its slot with the summon request, so the two never overlap.
- The floating pill of avatars at the top right is gone, which also settles the card to anchor the follow panel in the chrome.

## What this gives up

Following is one tap further away than before, behind the pill.
The chip and the outline keep the state visible and stopping it one tap.
