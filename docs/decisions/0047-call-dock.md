# 0047 - The call dock

Status: accepted (a design review); points 1, 2, 4 and 11 are built (#1517), the rest is not built yet except where a section says so
Date: 2026-09-30
Extends: 0004 (canvas tools are same-level, one-tap buttons), 0040 (mini-player and pop-out)

## Context

The call dock is the floating card a voice call and the canvas share.
`canvas_call_dock.dart` already builds one `FloatingDockCard` from whichever of `CallDockData` and `CanvasDockData` apply, so there is one component.
What is off is its size, its order and what its colours mean.
This record comes from a "current vs recommended" review captured against v0.82.0.
The numbers it quotes (about 1,430px stretched, about 620px hugging) are from that capture, not measured again here.

The record states what the code does at the time of writing, the change, and why, one section per accepted point.
Two points are left open on purpose, at the end.

## Decision

### 1. The dock hugs its content and stays centred

Today: in a call the dock is a centred pill.
With the canvas open, `CanvasCallDock` puts `CanvasToolsRow` in a `Flexible`, and the row is a `Row` with an `Expanded` tool strip, so the card stretches to the pane.
Call controls end up at one end, tools in the middle and close at the other.

Change: the card always sizes to its content and stays centred, and never stretches to the pane.
Opening the canvas grows the same pill (tools and edit join), closing it shrinks it back, with a 180ms ease-out on width and an instant change under reduce-motion.
In `canvas_call_dock.dart` the `Flexible` around the tools row goes, and `CanvasToolsRow` becomes `mainAxisSize.min` with no pinned trailing group.
The tool strip keeps its scroll-and-fade only for the case where even the hugged width does not fit.

Why: a bar that changes width when a mode opens reads as two different controls.
One pill that grows reads as the same control with more in it, and the far edge stops being a long pointer trip away.

### 11. The compact two-row stack stays

Today: below `kCompactWidth` the dock is two rows in one card, call on top and tools below, with 44px targets.
Change: keep the stack and the `kCompactWidth` branch, and only change the order (tools and undo on the top row, call row below with leave last).
More was meant to move into the call row so the tool row never scrolls.
Amended 2026-09-30, while implementing this in #1517: at 360 wide the call row cannot hold mic, camera, share, more, the canvas toggle and leave at 44px targets, so more stays with the tools and the top row can still scroll.
The consequence is that a phone user scrolls the strip to reach the eraser, which is tracked separately.

Amended 2026-10-01: #1526 then gave the five tools a row of their own, so the compact dock is three rows (tools; undo, canvas overflow and the canvas toggle; call with leave last), not two.
Two rows cannot hold every control without scrolling at 360: measured, the tools with the pen's options caret and undo already reach x=320 of 336, and the call row (mic, speaker, camera, share, leave) fills 293 of 336 before the canvas toggle and the overflow join it.
The eraser staying on screen was chosen over the row count, and `canvas_call_dock_tool_reach_test.dart` holds it at 360, 390 and 430.

Why: it already works, and the only thing wrong with it is the order that point 2 fixes everywhere.

Amended 2026-10-02, from the owner's phone ("dock ui on mobile a mess in canvas", "same for non canvas view"): the three-row stack above is replaced below `kCompactWidth` of the window.
In the canvas the tools get a one-row card and the call controls a second, separate one-row card, hugging their content and sharing a width, 124dp together at 390 against 176dp before.
Undo, the overflow menu and close moved into the canvas header, which has the room the bottom edge never had, and the overflow opens under its button there.
The eraser stays on screen without scrolling at 360, 390 and 430, held by `canvas_call_dock_tool_reach_test.dart`.
Outside the canvas a bot's call controls are one row at phone width: its name and a Bot badge as a small label, then one icon chip per control, the same chip the call row uses and labelled by tooltip and semantics.
The stage reserves the dock's measured height instead of a constant, so participant tiles are no longer hidden under a taller dock.
Between 600 and 800 the stacked layout above is unchanged, and so is everything at desktop width.

Amended 2026-10-02, from the owner's desktop screenshot (seq 195, "UI for desktop voice call, for streaming and such doesnt look good like mobile"): the bot row is the same icon-chip row at every width, since type and hit targets do not scale with width (desktop-vs-mobile.md, density).
The stage reserves the dock's measured height at every width, so participant tiles are never hidden under it.
A call dock with a bot row hugs its content (`FloatingDockCard.hugsWidth`) instead of stretching to the pane, because the hairline between rows used to widen the card.
With a share, the stage is a centred 16:9 card with the participant strip centred under it, so the video has no black band around it.
The canvas dock's own stacked rows are unchanged.
The channel's text chat on a phone is an app bar action beside members, not a floating button over the call (desktop-vs-mobile.md rule 2).

### 2. Leave is always last, after a divider

Today: `CallControls` already ends with leave, but in the combined dock the call row comes first and the tools after it, so leave is fourth of twelve.
Change: order is always tools, edit, call, leave, where tools and edit only exist while the canvas is open.
Leave sits after a 1x24 divider, is 44 wide, and is the only control with a danger outline.
One rule to learn: the far right of the dock ends the call.
`CallControls` stops drawing leave in its own row, and the card gets a trailing slot for it.

Why: a destructive control in the middle of a row of toggles gets hit by accident, and it should not move when the canvas opens.

### 4. The canvas button is a toggle in the same slot in both states

Today: `CanvasOpenButton` and `_CanvasToggleButton` in `voice_call_dock.dart` already take `active` from `canvasOpenProvider`, but the semantic label stays "Open canvas" and the canvas tools row has its own separate close X at the far right.
The header (`channel_header.dart`, `compact_channel_app_bar.dart`, `dm_call_pane.dart`) also shows a canvas icon.

Change: one canvas button, pressed while the canvas is open, in the same slot in both states.
Its label follows the state ("Open canvas" and "Close canvas"), and `CanvasDockData.onClose` is bound to that same button, so the separate X goes.
The header's canvas icon is not drawn during a call, because the dock already has the button.
Outside a call the header icon stays, since there is no dock.

Why: two controls for one thing, in different places depending on state, is what made the canvas hard to leave.

### 3. Accent means one thing

Implemented 2026-10-08, together with point 8.

Today: mic on, camera on and sharing all get the accent tint, and so does the selected pen, so "switched on" and "selected tool" look the same.
`CallDockButton` takes `active` and `destructive`, and the mic is lit while it is unmuted.

Change: accent marks only a selected tool or an open mode (the canvas toggle, sharing).
An ordinary on-state is a plain neutral icon.
Muted is a slashed mic with a danger outline.
The mic carries a live 2px level bar, from the local audio track, in the ok colour.
So "we can hear you" does not depend on colour, and it is visible with a colour-vision deficiency.
`AppIconButton(active:)` is for tools and modes only.

Why: one colour with two meanings trains people to ignore it.
Reserving it for "this is the thing you are using" makes it worth looking at.

### 5. Pan uses a hand glyph and comes first

Today: the fifth tool is `CanvasTool.select`, drawn with the four-way-arrows glyph (`AppIcons.select`, Lucide move), which reads as "move this object".
Change: pan gets a hand glyph and goes first, so the order is pan, pen, note, shape, eraser, with `H P N S E` shortcuts.
Pen, note and shape move to the custom glyphs from the identity review, eraser and pan stay Lucide.
Whether pan is also the default tool is an open question below, so this record does not decide it.

Why: the current glyph describes a different action than the tool performs.

### 6. Tool options appear as a card above the selected tool

Today: pen colour and width, and the shape kind already in `CanvasDockData`, have no visible control in the dock (the shape kind sits in the overflow menu).
Change: options appear only for the selected tool, as a small card anchored above it.
The pen gets six colours and three widths, shapes get rectangle, ellipse and arrow.
Pressing the selected tool again, or a long-press on touch, opens it, and Esc or picking closes it.
The flyout animates 180ms opacity and a 4px translateY.

This is the controls-with-options rule (below) applied to tools, so it must not invent a second gesture.

### 7. Undo and redo sit together, recenter leaves the dock

Today: there is undo and no redo, and recenter lives in the overflow menu.
Change: undo and redo sit together, redo dimmed when there is nothing to redo, on Ctrl+Z and Ctrl+Shift+Z.
Recenter moves out of the dock to a 28px zoom chip at the bottom right, outside the dock, showing the percentage and a fit action.
The overflow menu keeps paste image, activity log, hidden tiles, fullscreen and Clear last.

Why: recenter is what you need most on a bounded but very large canvas, and it is currently two taps deep.

### 8. The sharing banner goes

Implemented 2026-10-08, after the owner settled question 2 below.

Today: while sharing, `LocalScreenShareBanner` ("You are sharing your screen.", drawn by `call_stage_layout.dart`) sits above a share control, with a "Your screen" caption elsewhere and the camera tile stranded beneath.
Change: the share control itself carries the state (see the controls-with-options rule), and the tile's own label says "Your screen", inside the tile at the bottom left.
The banner is removed.
Privacy is an open question below and gates this point.

### 9. Call facts move into the header

Today: `_CallHeader` in `call_stage_layout.dart` draws "N in call - mm:ss" alone under the header, and `CanvasBar` says "Canvas" or "Canvas - name", dropping which call it belongs to.
Change: both headers show the channel name and the mode, then the count and timer in mono with tabular figures so the digits do not jitter.
`CanvasBar` becomes channel name plus mode, and the timer uses `AppText.micro` with tabular figures.

### 10. Alone in a call

Today: one large avatar in the middle of the pane, plus `_AloneHint` for the canvas mention (`isAloneInCall`).
Change: the local participant gets a normal tile (320x200, radius 10, the same component used at 2 and at 8 participants) with its label inside, and one line naming who could join, for example "Nadia and Kiki are online".
Names come from presence intersected with channel members, so it shows nothing new to anyone who could not already see them.
When someone joins, the grid adds a tile.

Why: for a small group this is the most common call state, and it is currently the emptiest.

## The controls-with-options rule

The owner settled this one, so it is a rule and not an option.

- A control keeps its primary action on a plain press.
- When it has more than one option it shows a caret that opens a menu.
- On touch, a long-press opens the same menu, with haptic feedback.
- With no options there is no caret and no long-press.

This replaces hidden long-press-only routes, such as the share button's "hold to change source".
It is being built as a design-system component on `feat/control-with-options`, applied to the share button first so the Wayland source switch stops being invisible.
The share control is therefore not a card under this record.
Mic, camera and tool options adopt the same component as they grow options.

## Open questions

These are recorded, not decided.

1. Should pan be the default tool on desktop?
   The review makes pan the default whenever the canvas opens, so a touch pans until a drawing tool is picked.
   On desktop, opening the canvas usually means wanting to draw, so a pan default may cost a click every time.
   The options are pan by default everywhere, pan by default on touch only, or remember the last tool.
2. Dropping the sharing banner lowers a privacy-relevant signal.
   The tile label and the share control carry the state, but the banner is the one cue that is hard to miss, and it is there so nobody shares by accident without noticing.
   Settled by the owner on 2026-10-07, who picked the card to drop it: the accent share control, whose tooltip and label read "You are sharing your screen. Stop sharing", and the stage caption are enough.
   The pending banner stays, since a share the system picker has not started yet must never read as live.

## Consequences

- The dock is one size rule, one order rule and one colour rule, so new controls have an obvious place.
- Work is split into cards by the files it touches, so two of them do not edit `canvas_tools_row.dart` at once; the cards say what to sequence.
- Nothing here touches the server or the wire protocol.
