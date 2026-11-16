<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0111 - A personal space is called Notes

Status: accepted
Date: 2026-11-10

## The ask

A DM with yourself, the personal space, needed a label for its rail row.
It shipped as `You` for a while, and the owner reversed that to `Notes`.

## Decision

The row is labelled `Notes`, from `personalSpaceName` in `providers/dms.dart`.
It names what the row is for rather than who it belongs to.
In a list of people `You` looks like another person, while `Notes` reads as the one row that is not a conversation.
It also matches the notebook icon the row already carries, and `Message #Notes` reads as an action rather than a pronoun.

## Tradeoffs

`You` matched the second-person convention used for the caller elsewhere, such as a voice tile's `$name (you)` and the personal settings group.
It also composed with the composer placeholder.
Both points still hold for `You`; they were outweighed, not wrong.

The label is cosmetic.
Another member can set `Notes` as their display name and a DM with them renders the same.
`Channel.isPersonalSpace`, not the string, is what the rail matches on.

## Amended 2026-11-16: Notes is a button beside the gear

The owner moved Notes out of Direct messages (option A2 of a side-by-side comparison of placements).

### Where Notes lives now

Notes is an icon button in the rail's bottom bar, immediately left of the gear.
It uses the notebook glyph and the same ghost `AppIconButton` as the gear, with the tooltip `Notes` and its shortcut.
It shows the active state while Notes is the channel on screen.
The Direct messages section lists only conversations with other people.

A row at the top of Direct messages read as a conversation, and Notes is not one.
It sat between the section label and the first real DM, so every DM list started with something that was not a DM.
The bar already holds the controls that are about you (your status, your settings), and Notes belongs with those.

What went with the row:

- The row's "Remove from list" menu, its confirmation toast and the per-account hidden flag behind it.
  The flag only existed to take the row out of the list, and the button takes no room in it.
- The palette's branch that un-hid Notes when it was picked.
  The palette still finds Notes by its name or by your own display name, and it is still a forward target.
- Notes in the next and previous channel order.
  `orderedChannels` lists only rows the rail shows, so cycling never lands on something that is not in the list.
  From Notes, next goes to the first row and previous to the last.

Notes has its own shortcut, `AppAction.openNotes`: Ctrl+Shift+N (Cmd+Shift+N on Apple), and Alt+Shift+N on the web, where every browser keeps Ctrl+Shift+N for a private window.
Opening it the first time creates it on the server, as the row did, and a failure shows over the rail as an `AppErrorState`.

### The call row

While a call is live anywhere but the channel on screen, its summary is a row of its own directly above the user bar.
It used to replace the name line inside the bar, which left no room for Notes.

- The speaker glyph sits over the avatar column, then the channel name and the timer.
- A tap goes back to the call, with the tooltip `Go to <channel>`.
- When the call is in another community, that community's name leads the second line, and a tap switches to it first.
- Leave is last on the row, over the gear, with the call dock's leave treatment from decision 0047 point 2: an always-on 2px danger outline and a danger fill on hover.
  Its glyph is the size of the bar's icons below it rather than the dock's smaller one.

The user bar keeps the avatar, name and status, mic and deafen while in a call, Notes, and the gear.
Every control in the footer carries a tooltip, the shortcut included where there is one.
Footer tooltips open upward, and the bar's open above the call row, so none covers Leave.

The phone gets the same bar and the same call row at 44dp touch targets, on the full-screen channel list and in the drawer (desktop-vs-mobile.md law 2).
