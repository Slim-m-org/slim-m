# 0017 - One canvas item, one right-click menu

Date: 2026-08-18.
Status: accepted; not yet built. Sub-questions resolved by the owner (see below).

This record captures a canvas-interaction direction the owner chose after a hands-on pass.
It knowingly amends parts of three earlier decisions, so the new reasoning is written next to the old rather than left to contradict it silently.

## The owner's own words, verbatim

On unifying media items (cameras, screen shares, images, gifs, screenshots):

> as an end user, i shouldnt even know there is a difference between the items in the canvas so if i want to click/drag/lock/do whatever to whatever i should be able to do it

On notes:

> if i place a note using left click, ill then want to left click to place another note, so maybe instead of being a tool, we can right click, click a context item "place note" and it will place a note under the context menus position and we wont be selected on a tool so we can just write in it ... so its not a tool itself, just a context option

On the right-click menu:

> when i right click while using a tool I should unselect it, and if I unselect pencil I should not have any of the draw tools selected, but if i right click again on canvas, I should have a sort of quick tool select area, which the tools in circular icons at the top of a context menu, and whatever other canvas settings, like undo, clear canvas, and if we are above a media item, it should include that items possible contexts

## What this reverses

1. **0010 treated cameras/screen shares (presence tiles) and drawn images (canvas objects) as two visibly different systems.**
That split is real in storage and stays (see below), but 0010 let it surface to the user: tiles carry on-tile control buttons and absorb right-click, while images use a separate object context menu.
This record makes that split invisible - one component, one action vocabulary - so the user never perceives which backend an item lives in.

2. **The note system's stated invariant "there is no in-place edit anywhere on this canvas" (`client/packages/app/lib/src/features/canvas/screens/canvas_note_sheet.dart:5-11`).**
Notes were authored in a bottom sheet, then painted, never edited in place.
This record replaces that with an inline draft note that is typed on the canvas itself.
The weaker invariant it actually protects - nothing hits the wire until commit - is kept.

3. **The two deliberate right-click no-ops:** the object menu's "empty canvas does nothing" (`canvas_object_context_menu.dart:41-48`) and a presence tile absorbing right-click (`canvas_presence_tile.dart:391`).
Both are replaced by one menu that resolves what is under the cursor and shows the right actions.

## The decisions

### 1. One media component, one action set; the storage split stays but goes invisible

Every canvas item - camera bubble, screen share, image, gif, screenshot - is presented through a single `MediaTile` component and offers the same actions: move, resize, lock, layer (front/back), hide/show, and remove.
From the user's side there is one kind of thing on the canvas and one way to act on it.

The object-vs-tile storage split from 0010 is kept, because it exists for a real reason a UI change cannot wish away: a live camera or screen share is ephemeral and tied to a participant's presence, and cannot be written to the op log and replayed the way a pasted image can.
So the seam moves *below* the shared component: the component and the action set are unified, and each action is interpreted against whichever backend the item uses.
"Remove" a shared image deletes it for everyone; "remove" a live camera hides that tile - same button, contextually correct effect, no visible difference in how you reach it.

Full storage unification (collapsing objects and slots into one system) was considered and declined: it fights 0010 for the live/ephemeral reason above and is a large, risky rewrite of storage, sync, and the op log, for no gain the user can perceive over unifying the surface.

This also closes a class of bug rather than one instance: today the control chrome is implemented per subsystem and drifts from the content (a back tile's controls painting over a front tile is one symptom).
One component solves the ordering and controls once.

### 2. A note is a right-click action, not a dock tool

"Place note" leaves the tool dock and becomes an item in the canvas right-click menu.
Right-click where the note should go, pick "Place note," and a note is dropped at the cursor with the caret focused for immediate typing, with no tool armed and nothing locked.

This is the owner's own resolution of a flaw in the tool version: a placement tool stays armed, so the click that should start typing places another note instead.
As a context action the conflict does not arise - placement is a discrete choice, and the very next click is free to land in the note.

The inline draft is the canvas's first live, locally editable widget.
The world-to-screen geometry it needs already exists (`presenceScreenRect`, `canvas_presence_geometry.dart:105-110`, and the camera-tracking overlay pattern in `CanvasPresenceLayer`).
Nothing is sent until the draft commits (blur / Enter), preserving the one note invariant worth keeping.

### 3. One right-click menu that resolves what is under the cursor

Right-click behavior is unified into a single menu with three context modes:

- **While a tool is active:** right-click deselects the tool.
There is a genuine "no tool armed" state after this (the tool enum gains a none/unset value); deselecting the pencil leaves no draw tool selected.
- **On empty canvas with no tool:** the menu opens with the drawing tools as icon buttons at the top, plus canvas actions - undo, clear canvas, and "Place note."
- **Over a media item:** the same menu also carries that item's actions (lock, layer front/back, hide/show, remove), reached the same way for every item type per decision 1.

Redo is deferred.
There is an undo history today but no redo, so the menu ships undo-only for now; redo is a separate, later piece of work on the canvas op history, and the menu is built so a redo entry can be added without rework.

## What this deliberately does not do

- It does not unify storage (decision 1).
- It does not build redo (decision 3).
- It does not remove the on-tile controls as a prerequisite; whether the unified menu fully replaces them or they coexist is a build detail, not a decision here.

## Sub-questions, resolved by the owner

- **Inline-note camera behavior: the draft is world-anchored and does not lock the canvas.**
In the owner's words:

> they can like middle click drag around while focused on a note and after dragging as long as they didnt click or lose focus they should be able to type in note, the note itself should not change position if someone moves, its on the canvas the moment someone places it, so unless they intentionally move it it doesnt

So a note is placed at a world position and stays there; middle-click pan works while the draft is focused, the draft re-anchors to its world point as the camera moves, and only a click elsewhere or an explicit focus loss ends editing.
This is the camera-follow cut, not lock-while-editing.

- **"Remove" adapts to what is under the cursor: image removes, live tile hides.**
In the owner's words: "if image, remove, if screenshare/camera hide is fine."
The menu resolves the item type and shows "Remove" for a canvas-object image/gif and "Hide" for a live camera/screen share.

- **Hit-test priority: tile, then object, then empty.**
The resolver checks a live presence tile first (they paint topmost), then a canvas object (image/stroke), then falls back to the empty-canvas menu, matching visual stacking so the menu always acts on what is visually under the cursor.

## Build map

- Unified component / action set: `canvas_presence_tile*.dart`, `canvas_object_context_menu.dart`, `canvas_presence_tile_controls.dart`, and the object vs `canvas_media_slots` backends.
- Inline notes: replace `showCanvasNoteSheet` (`canvas_note_sheet.dart`) with an inline draft overlay; reuse `presenceScreenRect`, `_NoteByteLimitFormatter`, `CanvasQuickPlacement.placeNote`.
- Unified menu + tool state: `canvas_pane.dart` (`_tool` state gains none), `canvas_pane_gestures.dart`, `canvas_pane_body.dart` (gesture layering), `CanvasTool` enum (`canvas_surface.dart:60`).
- Paint-order fix that unification subsumes: `presencePaintOrder` (`canvas_presence_geometry.dart:89-100`) should sort `sentToBack` ahead of touch-order.
