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
