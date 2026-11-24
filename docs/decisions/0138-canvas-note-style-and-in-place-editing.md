<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0138 - Canvas notes: edited in place, styled, and rendered as Markdown

Status: accepted
Date: 2026-11-24

## The ask

The owner, 2026-11-24, with screenshots:

- "no control over notes, background transparency, colors, markdown, etc"
- "you never edit a note directly, it opens a text box ... looks bad"

This supersedes the "Client" section of [0072](0072-editable-canvas-notes.md): the editor panel with Save and Cancel, and the sheet that placed a new note.
The rest of 0072 stands: the `edit` op, who may edit, locks, the no-op rule and "mentions do not notify".

## Decision

### The note is the field

Editing a note types into the note itself.
The field sits exactly over the note's rect, with its padding, font, line height and colours, scaled by the camera, so the box on the board and the box being typed in are one thing.
The painter leaves the note's text out while it is edited, so the field is the only copy.
The note grows to hold what is typed (never shrinks), and on commit it grows once more to the rendered Markdown layout.

- A double click, a tap on an already selected note, Enter on a selected note, or "Edit note" in the object menu starts it.
- A click or tap outside the note and its bar, Ctrl or Cmd plus Enter, or picking another object commits.
- Escape cancels, and so does editing down to nothing, since the field has no way to delete a note.
- On touch there is no Escape, so cancelling is undo (each commit is one undo entry) or Android back.
- On a phone the camera pans so the note stays above the keyboard.
  A note smaller than body text on screen eases the camera up to it first, a move the system makes and so may animate.
- While others act: the field follows remote moves, resizes and the camera every frame.
  A remote erase closes it and shows the persistent `AppErrorState`, and undo restores the note.
  A lock during the edit makes the commit fail with a conflict, and the field stays open with the same error.
  Text and checkbox toggles stay last write wins: two people ticking different boxes at the same moment can lose one tick.

A new note is placed the same way.
The Note tool makes a draft note at the spot, in the last used style, with the field open.
Nothing is sent until it is committed, which keeps the old sheet's property that nobody sees you typing.
Escape or empty text discards the draft, and a refused place keeps the draft open with its text.
The placement sheet is retired.

### Style

Four optional props on a note, all additive:

| prop | meaning |
| --- | --- |
| `fill` | the note's colour, fill and outline: a palette key or `#rrggbb`; absent is the amber every note had |
| `fill_opacity` | 0 to 1; absent is 0.18, the tint every note had |
| `color` | the text colour: a palette key, `#rrggbb` or `auto`; absent is `auto`, which keeps the theme's ink while it reads on the fill and flips to a dark or light one when it cannot |
| `size` | `small`, `medium` or `large`, the text box steps, scaling the box-derived size by 0.7, 1.0 and 1.2 |

Opacity has three steps in the UI: solid (1), tint (0.18, what a note without the prop shows as selected) and clear (0, the outline stays so the note can still be found and hit).
A bar floats above a selected note, and under 600 it docks full width above the keyboard and the call dock and scrolls sideways.
It holds the fill colour row, the opacity and size segmented rows, the text colour row and, while typing, an emoji button.
The Note tool's options show the same groups, so a style can be picked before placing; new notes take the last style used.
Each change is one `edit` op and one undo entry, and a failure shows as an error on the canvas, never a snackbar.
Reachable from the object menu ("Style"), which puts the keyboard on the bar.

### The server merges note edits

For a note, an `edit` merges at the top level: a key left out keeps its stored value and `null` deletes the key.
The merged object is validated again and checked against the props size limit, and the no-op check compares parsed values, so key order never makes an edit.
The edit result, the op log and `canvas.object.edited` all carry the merged props, so every receiver sees one truth.
Text boxes stay a wholesale replace.

This is what keeps old clients safe.
A shipped client edits a note with `{text, font_size}` and a bot such as the homelab one with `{text}`; without the merge either would erase the style.
Validation checks only the known keys (types, colour keys or `#rrggbb`, opacity in range) and that `text` is a string.
`font_size` and any unknown key pass, and there is no hidden-character rule on note text, which would reject ZWJ emoji and tabs that clients and bots send today.

### Markdown on the board

A displayed note renders headings, quotes, bullet and numbered lists, task boxes, fenced code and the inline marks the messages parser knows.
It is built from the message splitter with a notes-only option, so messages render as before.
A painter cannot lay out widgets, so structure is prefixes, sizes and weights over the base style, and a task box is a gap the painter draws a box into.
Heading sizes are the note's base size times ratios of the design system's type scale.
The raw text is what is edited.

Links stay bare `http(s)` addresses and `<url>`, as in messages, so a note can never show one address and open another.
Message links and channel mentions open inside the app, as they do in messages.
Ticking a box is an ordinary edit that rewrites that source line, follows edit permissions, and is not offered on a locked note or to a spectator; links open for everyone.

## Old clients

A shipped client reads only `text` and `font_size` of a note (`_noteInputFrom`, `client-v0.136.0` `canvas_object_inputs.dart`), so a styled note draws as the ordinary amber note with the same text and box.
Block Markdown and `- [ ]` show as typed.
Its text edit keeps the style because the server merges.
No migration, no new route, no new op kind.

## Rules cited

- [desktop-vs-mobile](../design/desktop-vs-mobile.md) translation table row "inline edit-in-place -> the same, composer expanded to fit; never a separate edit screen".
- Law 1 (width decides: the bar floats from 600 up and docks below), Law 2 (30 to 38dp rows with a pointer, 44dp and up on touch) and Law 3 (every hover or double click has a long press path: the object menu opens on a long press).
- Surface rule 1 (actions on a pointed-at object are a context menu: "Edit note" and "Style") and rule 2 (a segmented row for two to four options: opacity and size).
- Never-rules: opacity and size are segmented rows, not dropdowns; Escape is not the only way to cancel; a failure is an error on what failed, not a toast.
- The design language's motion rule: the camera ease is a system move, and nothing animates pane width.

## Alternatives rejected

- A `style` sub-object: text boxes already keep flat props.
- A slider for opacity: three steps are enough and each is one op.
- A field scaled with a `Transform`: the IME caret and selection handles drift.
- Widget-tree Markdown over the board: it cannot zoom with the painter.
- Masked `[label](url)` links: left out until the owner asks, with the real destination shown before opening.
