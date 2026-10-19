<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0072 - Editable canvas notes

Status: accepted
Date: 2026-10-18

## The ask

The owner said: "I wanted the notes to be interactable, majority of input boxes should support the same functionality, pinging @ users, markdown, editable".
He chose "Editable notes" over a read-only notes pass.

## Decision

A note's props can be replaced after placement with a new canvas op kind, `edit`.
An edit is authorized like a move: the author needs nothing more, anyone else needs `MANAGE_CANVAS`.
Only notes can be edited, a locked note refuses it with a conflict, and an edit that leaves the props unchanged is a no-op that publishes nothing.
The props follow the same size limit as a placement.

The edit is a row in the op log (migration 0136 adds `edit` and an `edit_props` column), so undo, redo and a reconnecting client replay it by `seq` like every other op.
A live edit goes out as the `canvas.object.edited` frame, carrying the object id and the new props.

## Client

Double click (or tap on touch) on a note you may edit opens it in place.
The editor reuses the composer's mention autocomplete and emoji picker, and the note renders markdown and mentions.
A locked note, or one you may not edit, never opens the editor.

## Mentions do not notify

A mention in a note is rendered as a mention but pings nobody.
The server's mention pipeline is built around messages: notifications and push are keyed by message id and a channel's read state.
A note has neither, so reusing it would mean a parallel notification kind, which is a separate decision.
