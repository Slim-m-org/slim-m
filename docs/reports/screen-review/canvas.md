# Canvas review - merged

Three independent lenses (frontend implementation, UX/accessibility, backend/contract) reviewed the same screenshot set and code paths, merged here per screen or family.

## What this covers

The Voice Canvas surface: the empty/busy/quiet assembled panes, the ten error states, loading, the clear-canvas confirmation, the overflow menu, the activity log, the four tool states, presence bubbles, and the isolated painter fixtures (zoom stress, selection handles, note overflow, multi-user cursors, live ink, kitchen sink, elevation).
This area has two harnesses, and they disagree with each other in the most important finding below: the 39 `canvas-assembled/*.png` screenshots render the real pane through the real shell, and the `canvas-painters/*.png` set renders each `CustomPainter` in isolation with no shell around it.
Desktop, phone, and phone-landscape variants read where captured.
Copy was checked against its real call site and against server behaviour, not just read as text.

## The short version

- The background grid never paints in the real app, in any of the 39 assembled screenshots, though it paints correctly in every isolated painter fixture - a one-widget regression the isolation harness cannot see. **Still open** - not attempted in this pass.
- ~~The clear-canvas confirmation says "This cannot be undone" while the same client arms a working local undo for that exact action, found independently by two different backend passes (this one and the overlays review) and read as fine by the UX pass on copy grounds alone.~~ Fixed 2026-08-10.
- ~~The overflow menu truncates "Paste image" to "Paste i…" and "Hide my camera bubble" to "Hide my camera bu…", found independently by the frontend and UX lenses.~~ Fixed 2026-08-10.
- ~~The canvas loading state shows a sighted user nothing at all - no spinner, no skeleton - identical to a blank or broken canvas, while a screen reader gets a label.~~ Fixed 2026-08-10.
- ~~A resize handle's hit target is 28px across, well under this product's own 44-48dp floor, and never grows for touch.~~ Fixed 2026-08-10.
- ~~Two forbidden-drawing error states (channel-wide refusal, timeout freeze) leave the empty-state hint and the pen tool inviting a repeat of a refusal the client already knows will fail again.~~ **Fixed 2026-08-10/11**: the empty-state hint, the pen/note/shape tools and "Paste image" are all now gated on `widget.error`. The timeout wording still does not name the actual timeout time - that half needs new plumbing and is still open, see the sections below.

## Background grid lattice never paints in the assembled pane

Verdict: real, high-confidence, high severity, and the single most important finding in this review.

- `GridPainter` (`canvas_painters.dart`) draws the background lattice - "the background lattice, at a spacing quantised to the zoom" - and it renders correctly in every isolated painter fixture: `kitchen_sink_*.png`, `elevation_*.png`, and `zoom_stress_*.png` all show a visible grid.
- It is completely absent from all 39 `canvas-assembled/*.png` screenshots: `empty-desktop-1400-dark.png`, `busy-desktop-1400-dark.png`, `quiet-desktop-1400-dark.png`, every error state, every tool state, loading, the overflow menu, the activity log, clear-confirm.
  Confirmed by pixel-cropping empty background regions in several of these, in both light and dark theme: flat colour, no lattice.
- Root cause, read from source: `CanvasGridLayer` (`canvas_grid_layer.dart`) is `CustomPaint(painter: GridPainter(...))` with no `child` and no explicit size.
  A bare `CustomPaint` with no child sizes itself to `Size.zero`, Flutter's own documented default, unless something else constrains it.
  It is mounted as the first, non-positioned child of the `Stack` in `canvas_pane_body.dart`'s `_surface()`, and that `Stack` never sets `fit: StackFit.expand`.
  Under the default `StackFit.loose`, the non-positioned `CustomPaint` collapses to zero size, so `GridPainter.paint` runs with `size == Size.zero` and every drawing loop draws nothing.
  `CanvasSurface` (`canvas_surface.dart:320-357`) avoids the same trap only because it wraps its own paint stack in a `LayoutBuilder` plus an inner `Stack(fit: StackFit.expand)`, a mechanism `CanvasGridLayer` does not have.
  `CanvasGridLayer`'s own doc comment even asserts the behaviour that is broken: "the grid alone, sized to fill whatever space its parent gives it."
- This is a regression from PR #505, which extracted the grid into its own widget so it could sit under sent-to-back tiles.
  The one existing test that touches it, `canvas_presence_depth_test.dart`, asserts only ordering of widget types in `Stack.children` ("the grid must sit under a sent-to-back tile's own video"); it never asserts the grid actually paints or has non-zero size, which is why this shipped and stayed unnoticed - the test checks that the painter is mounted in the right place, not that it paints.
- A fix is in flight (give `CanvasGridLayer` its own sizing, e.g. `Positioned.fill` or `SizedBox.expand` around the `CustomPaint`, independent of the parent `Stack`'s `fit`); recorded here as found, not as still open.
- Severity: high.
  This is a documented, load-bearing piece of the canvas's visual language, the spacing-quantised lattice that orients a large bounded world, and it has never actually been visible to a user in the assembled pane, in any theme or scenario.

## Clear-canvas confirmation contradicts its own undo

Fixed 2026-08-10, per the "Fix" line below: the dialog no longer claims permanence and now names Undo directly ("You can undo this with Undo until you close the canvas or take many more actions.").

Verdict: high severity, source-confirmed contradiction, found twice from two different directions.

- The confirm text, read verbatim from `canvas_overflow_menu.dart:152-153`: "This removes all N objects from the canvas for everyone in this channel. **This cannot be undone.**"
- `CanvasOpsController.clear()` (`canvas_ops_controller.dart:209-227`) pushes `_pushUndo(_EraseEntry(result.op.id))` on a successful clear, and `undo()` for an `_EraseEntry` (`canvas_ops_controller.dart:119-126, 251-262`) submits `kind: 'restore', target_op: opId` against the same server route this dialog warns about.
  Server-side, `apply_restore` (`store/canvas_ops_apply.rs:212-...`) genuinely reverses a clear: it re-authorizes the original op and re-checks every candidate object against the `deleted_at` fence the clear set, and a successful restore fans out `Event::CanvasObjectsRestored` to the whole channel, exactly as public as the clear it reverses.
- This is not hypothetical: `client/packages/app/test/features/canvas/canvas_ops_controller_test.dart:329-351` is titled, verbatim, `'clear removes local ink at or below the fencing seq and can be undone by restoring it'`.
  The test suite's own name states the opposite of what the dialog tells the user.
- The audience that sees this dialog is exactly the audience that can immediately falsify it: "Clear canvas" only appears in the overflow menu when `canManage: true` (`canvas_overflow_menu.dart:6-7, 43`), and that same caller's dock carries the Undo control, wired to the same `CanvasOpsController` instance, in the same view.
  There is no intervening step, no different permission, and no different session.
- Caveat that belongs in the fix, not a mitigation of the finding: the undo stack is in-memory, capped at 32 entries and evicted oldest-first (`canvas_ops_controller.dart:37-38, 264-269`), and is discarded when the pane closes.
  So "cannot be undone through this control, past this session or after 32 more actions" is true; the dialog says something stronger and unqualified.
- This was found twice, independently: once in the overlays-area review (`docs/reports/screen-review/overlays.md`'s `confirm-clear-canvas-one`/`confirm-clear-canvas-many` finding, against the same dialog reached through a different fixture) and again here, going further by naming the test whose own title contradicts the dialog's own claim.
- Worth recording as a genuine disagreement rather than smoothing it over: the UX lens in this same review read the identical dialog under "Clear confirmation" and called it "reads well... no finding," judging it purely on whether the sentence states the count, the blast radius, and irreversibility clearly.
  It does state those three things clearly.
  It is also false, and copy quality was never going to catch that on its own - the sentence is well written and wrong.
- Fix: either make the copy honest ("You can undo this with Undo until you close the canvas or take many more actions") or, if Clear is meant to be genuinely irreversible, stop pushing an `_EraseEntry` in `clear()` so the code matches the copy.
  Given the server already treats a clear as a reversible, restore-fenced op, rewording the dialog is the smaller, more honest change.
- Severity: high.

## Canvas overflow menu truncates two of its own labels

Fixed 2026-08-10, the widen-it option from the "Fix" line below: `width: 200` is now `width: 280`, wide enough to fit "Hide my camera bubble" without truncating; the shortcut hint was left in place rather than dropped.

Verdict: real, easily reproduced, found independently by two lenses.

- `canvas-overflow-menu-open-with-conditional-items-desktop-1400-dark.png` shows "Paste image" truncated to "Paste i…" (the trailing `Ctrl+V` hint eats the remaining width) and "Hide my camera bubble" truncated to "Hide my camera bu…".
- `canvas_overflow_menu.dart:234` passes `AppMenu(width: 200, ...)`, narrower than `AppMenu`'s own default of 250 (`design_system/lib/src/components/surfaces/menu.dart:39`).
  200px is not enough for this menu's own longest items once a leading icon and a trailing keyboard-shortcut chip are both present.
  "Recenter view" (13 characters, no trailing hint) fits fine in the same menu, which is what makes the truncated items read as broken rather than intentionally abbreviated.
- Fix: drop the explicit `width: 200` override, or widen it enough to fit "Hide my camera bubble" plus its leading icon without wrapping or truncating; alternatively drop the shortcut hint from "Paste image" on desktop the way it is already dropped on touch layouts (`AppTouchTargets.of(context) ? null : _shortcutHint(context)`) - the hint is decoration, the label is the part that has to stay legible.
- Severity: high.
  "Paste i…" specifically drops the one word that says what the item does, and this is the first place a new canvas user looks for how to add an image.
- Everything else in the menu - Recenter view, Show/Hide activity log, the conditional camera-bubble item, Clear canvas in the danger outline treatment - reads clearly with no truncation, and the conditional gating (Bring to front/Send to back/Delete withheld when no selection is live) matches `canvas_overflow_menu.dart:77-89` exactly.

## canvas-error-forbidden / canvas-error-draw-forbidden-timeout-freeze

Verdict: both messages match a real server refusal, but in both cases the rest of the pane keeps inviting the same guaranteed failure, and the timeout message specifically does not say it is a timeout.

- `'The canvas is not available in this channel.'` fires only from `canvas_pane.dart:279-284` on `api.ForbiddenException` from the viewport load, and the server refuses on exactly one condition, `!permissions.contains(VIEW_CHANNEL | USE_CANVAS)` (`crates/slimm-server/src/http/canvas.rs:141-142`).
  Message and trigger line up.
~~Finding (medium): the pane keeps the full drawing surface live underneath the banner.
  `_error` is never consulted to gate the tool row, the dock, or the empty-state hint - `canvas_pane_body.dart:355` shows `_emptyHint` whenever `count == 0 && !widget.loading`, with no check of `widget.error`.
  So the pane simultaneously says "the canvas is not available in this channel" and invites the same person, in the same screen, to "Draw with the pen, drop a note or a shape, or paste an image" (`canvas_pane_body.dart:452-454`), pen tool shown active.
  Any attempt through that CTA hits the identical `VIEW_CHANNEL | USE_CANVAS` gate on the write route (`canvas_write.rs:132-133`) and fails the same way, since nothing about the permission state changed between the two calls.
  Evidence: `canvas-error-forbidden-desktop-1400-dark.png`.
  Partially fixed 2026-08-10: the empty-state hint is now gated on `widget.error == null`, so it no longer invites drawing while this exact banner is up. The tool row and the dock are still not gated on `widget.error` - the pen tool remains selectable and would still hit the same refusal.~~
  Fully fixed 2026-08-11: `CanvasDockData`/`CanvasToolsRow` gained a `canDraw` field, threaded from `CanvasPaneBody._dockData()` as `widget.error == null`, and pen/note/shape (plus the overflow's "Paste image") now render with `onPressed: null` whenever an error banner is up, matching the `Undo` button's own disabled-when-nothing-to-do pattern rather than a new mechanism. Eraser and select are deliberately left alone - see `canvas_tools_row.dart`'s own doc comment on `canDraw` for why. `canvas_pane_body_error_gates_drawing_test.dart` drives `CanvasPaneBody` directly with a real error string and asserts both controls are disabled; `canvas_tools_row_test.dart` proves the row itself gates correctly given the flag.
- ~~`'You cannot draw on this canvas right now.'` is the shared `ForbiddenException` mapping in `canvas_commit_queue.dart:182`, `canvas_quick_placement.dart:122` and `canvas_image_paste.dart:166`~~ - all three `place`-path callers, exactly the scope CLAUDE.md documents for the timeout freeze (`move`/`reorder` freeze the same way; `remove`/`clear`/`restore` never do).
  The wording never overstates the freeze to cover erase or undo.
- ~~Finding (high, UX lens): the message gives no indication it is a timeout specifically.
  A person on a channel timeout has no way to distinguish "I'm timed out" from "this channel doesn't allow drawing" from "something's broken."
  The client already fetches `timedOutUntil` on a `UserProfile` and renders it elsewhere (`member_profile.dart`), so the data exists in the product even though this call site does not have it wired up.
  Minimum fix without new plumbing: reword to read unambiguously as a permission state rather than a transient outage, e.g. "You don't have permission to draw here right now."~~
  Minimum fix applied 2026-08-10, verbatim: all three call sites now read "You don't have permission to draw here right now."
  The better fix - naming the actual timeout time - is not built; it needs new plumbing to fetch `timedOutUntil` at this call site, which the report itself flags as the harder half.
~~Finding (medium, same root cause as canvas-error-forbidden): this error is set via `CanvasCommitQueue.onFailed` (`canvas_pane_helpers.dart:33-38`), which calls `_document.kill(id)` before setting `_error`.
  If the failed stroke was the only object drawn, `objectCount` returns to 0 and the empty-state hint reappears with the pen tool still selected, immediately after a banner saying the opposite.
  The pen tool itself is not gated by `widget.error` and stays selectable; a timed-out member who taps it still reaches the same 403 every time until the timeout expires, since there is no server-side signal in the response that would let the client disable the tool proactively (`timed_out_until` is only ever asked at write time).
  Evidence: `canvas-error-draw-forbidden-timeout-freeze-desktop-1400-dark.png`.~~
  The empty-state hint half was fixed 2026-08-10 (see Canvas loading state below).
  The pen tool half is fixed 2026-08-11, by the same `canDraw` fix as canvas-error-forbidden above: this call site sets the identical `_error` field, so the pen tool is disabled here too, for as long as the banner is up - closing exactly the repeated-403 case this finding named, without needing the `timedOutUntil` plumbing the wording fix below still does.

## canvas-error-full-canvas / canvas-error-too-large

Verdict: a genuine disagreement between lenses on the same sentence, plus one separate, smaller wording gap.

- ~~`'This canvas is full, or that id is taken.'` covers `ConflictException` from `PlaceError::ChannelFull` and `PlaceError::IdConflict` in one sentence (`canvas_write.rs:176-179`, `canvas_commit_queue.dart:182-183`).
  The backend lens calls this accurate and low severity: folding two distinct 409 reasons into one honest "or" sentence is correct to both, and the third `ConflictException` shape (`PlaceError::Removed`) is correctly split into a separate message rather than folded in here.
  The UX lens calls the same sentence a leaked internal detail and high severity: "that id is taken" names an implementation detail (an object-id collision) a viewer never typed and cannot act on, and it is the *only* one of three near-identical `ConflictException` handlers that says it this way - `canvas_quick_placement.dart:122` and `canvas_image_paste.dart:166` both already say the plain `'This canvas is full.'` for the same exception type.
  Recorded as a disagreement rather than resolved in this document: the sentence is technically accurate to two server states, and it is also the only one of three sibling call sites that exposes the id-collision half to the person reading it.
  Given the shorter sentence is already proven copy two files over, the simplest fix - dropping the id-taken clause and matching the other two call sites - satisfies both readings, so it is worth doing regardless of which severity is credited.~~
  Fixed 2026-08-10, the simplest-fix reading: `canvas_commit_queue.dart` now says the plain `'This canvas is full.'`, matching the other two call sites.
  Severity: medium.
- Finding (low, backend lens): `'That stroke was refused as too large.'` covers `BadRequestException` on the stroke path, which can only be `PlaceError::OutOfBounds` ("the object is outside the world or too large") or the `MAX_PROPS_BYTES` check ("canvas props are too large") - `canvas_write.rs:171-175` and `:146-148`.
  "Outside the world" is a materially different failure than "too large" (a correctly-sized stroke placed via a pan/zoom edge case could be rejected as out-of-bounds), and the message picks "too large" for both.
  `splitStroke`'s own byte-budget quantization makes the props-too-large branch the overwhelmingly likely real cause in practice, which is why this is low rather than higher.

## canvas-error-generic-load

Verdict: text matches (an honest fallback for any non-forbidden `ApiException`), but the only recovery offered is Dismiss.

- Confirmed in `canvas_pane.dart` that `Dismiss` only clears `_error` (`onDismissError: () => setState(() => _error = null)`); it never re-fetches.
  This message covers an almost-certainly-transient network failure, and the only way forward available on screen is to close the canvas pane and reopen it, which nothing tells the person to do.
- Fix: add a "Retry" action beside Dismiss that re-runs the same fetch.
- Evidence: `canvas-error-generic-load-desktop-1400-dark.png`.
- Severity: medium.

## Canvas loading state

Fixed 2026-08-10, per the "Fix" line below: a `CanvasLoadingHint` (split into `canvas_pane_hints.dart` alongside the empty-state hint once the body file crossed the 500-line hard ceiling) shows a small `CircularProgressIndicator` centred over the canvas while loading, gated the same `if (widget.loading) ... else if (count == 0 && widget.error == null) ...` way the empty hint already was. Under reduce motion it renders as a determinate, static ring (`value: 0.75`) rather than the usual spinning one - narrower than this project's general "leave platform spinners ticking" precedent, because this specific surface sits inside `HomeShell`'s wider canvas swap-in, which its own pre-existing test (`home_shell_canvas_test.dart`) already asserts settles to zero running animations under reduce motion.

Verdict: real, and it lands on the signature feature's first impression.

- `canvas-loading-desktop-1400-dark.png` is a flat, featureless rectangle with no spinner, skeleton, or any sighted-user indication the canvas is loading - pixel-identical, in the region that matters, to what a broken or blank canvas would look like.
- `canvas_pane_body.dart:346-355` changes only the `Semantics` label (`'Canvas, loading'` vs. `'Canvas, ${_summary()}'`) while `loading` is true, and the empty-state hint is explicitly suppressed (`if (count == 0 && !widget.loading)`) with nothing shown in its place.
  The surrounding comment names the exact risk this leaves open for sighted users ("a blank canvas otherwise looks identical to a broken one") and only answers it for screen readers.
- Fix: show a visible loading indicator - a spinner or skeleton matching whatever loading affordance the rest of the app already uses - gated the same way the empty hint already is.
- Severity: medium-high.
  First impressions of the signature feature ride on this screen, and a slow fetch here is currently indistinguishable from a stuck one.

## Presence bubbles over canvas content

Verdict: the overlap itself is a deliberate, documented tradeoff; two separate, fixable gaps sit on top of it.

- `busy-desktop-1400-dark.png` (and every `busy-*` variant) shows Jordan's and Priya's avatar-only presence markers sitting directly on top of `note-callout`, blotting out roughly half of every line they cross.
  This is deliberate and already documented: `CanvasPresenceLayout` places call tiles in a fixed top-left row sorted by identity with no awareness of what is underneath, and the fixture's own doc comment says a real session has no way to know where bubbles will land before drawing - not a new finding, and not something a layout fix can safely undo.
- ~~Finding (medium, frontend lens): `_AvatarMarker`'s name caption (`canvas_presence_bubble.dart:59-126`) renders as plain text with only a drop shadow tuned for the plain canvas background, unlike the camera-tile `_NameBadge`, which sits on a translucent `surfaceBase` pill.
  Against a light note fill the shadow buys nothing and the label reads directly against the note's own text underneath it.
  Since the overlap itself is accepted as unavoidable, the label should stay legible wherever it lands; fix by giving the caption the same translucent-pill background `_NameBadge` already uses.~~
  Fixed 2026-08-10, exactly that fix: the caption now sits on a `tokens.surfaceBase.withValues(alpha: 0.72)` pill, matching `_NameBadge`'s own treatment.
- Finding (low-medium, UX lens): there is no way for a viewer to hide *other* participants' bubbles to read what is underneath one that is in the way.
  The overflow menu's "Hide my camera bubble" only affects the viewer's own bubble, and object z-order controls (send-to-back, confirmed working in `busy-desktop-1400-tile-sent-to-back-dark.png`) do not apply to presence bubbles at all.
  Workable today by asking the blocking person to move their own bubble; not self-serve for the person being blocked.
  Suggest a "Hide camera bubbles" toggle (all of them, viewer-local) alongside the existing self-only one.
  Evidence: `busy-desktop-1400-dark.png`, `busy-desktop-1400-tiles-manipulated-dark.png`.

## Activity log (accessibility fallback)

Fixed 2026-08-10, per the "Fix" line below: `CanvasActivityPanel` now renders "Activity from before you joined isn't shown here." when `objectCount > 0` and the log is empty.

Verdict: the summary line and the log body contradict each other in the fixture, and the same shape can occur for a real user.

- `canvas-activity-log-open-desktop-1400-dark.png` shows "11 objects: 2 strokes, 2 images, 3 notes, 4 shapes" directly above "No canvas activity yet."
  A person who cannot see the canvas reads that as: there is content, and nothing happened to create it, which is a contradiction rather than an answer.
- Not a fixture-only quirk: per this codebase's object-vs-op disclosure design (catch-up ops populate the log, a raw object snapshot does not), a canvas whose content predates this viewer's activity-log session, or whose earlier ops have aged past retention, can legitimately land in exactly this state for a real user.
  For the person this panel exists for, the summary counts say *how many* strokes/notes/shapes exist but never *what they say*, and pairing that with an apparently-empty history reads as the panel having failed rather than as "this content predates what's tracked."
- Fix: add a line to the empty state when the object count is nonzero but the log is empty, e.g. "Activity from before you joined isn't shown here," so the two numbers stop contradicting each other.
- Severity: medium.
  This is the one surface built specifically for someone who cannot verify the discrepancy by looking at the canvas itself.
- Not independently checkable from this fixture: the actor-attribution asymmetry CLAUDE.md documents (catch-up discloses a moderator's identity to a `MANAGE_CANVAS` holder, live frames never carry one at all) has no populated entries in this screenshot to confirm against, so it is taken as read rather than re-verified here.

## Selection handles: resize hit target too small for touch

Fixed 2026-08-10, per the "Fix" line below, verbatim: a new `touchResizeHandleHitRadius = 22.0` in `canvas_resize.dart`, and `canvas_pane_gestures.dart`'s `_onSelectStart` now passes `touch: AppTouchTargets.of(context)` through `beginSelect` to `hitTestResizeHandle`.

Verdict: real, high severity, a core canvas manipulation rather than an edge case.

- `resizeHandleVisualSize = 9.0` (drawn size) and `resizeHandleHitRadius = 14.0` (a radius, so a 28px-diameter hit circle) are fixed constants in `canvas_resize.dart` with no touch-target branch, unlike the overflow menu's shortcut hint elsewhere in the same feature, which already checks `AppTouchTargets.of(context)`.
- `docs/design/design-language.md` sets this product's own accessibility bar at "minimum 44 to 48dp touch targets"; a 28px corner handle is roughly two-thirds of that floor.
  On a phone, grabbing a specific corner to resize a note or image will be disproportionately hard to land precisely, especially at low zoom where the visual square shrinks toward the hit radius's own size.
- Fix: branch `resizeHandleHitRadius` the same way the overflow menu already branches its shortcut hint - a larger hit radius (22px, giving a 44px target) on touch, keeping the tighter 14px on mouse/trackpad where precision is cheap.
- Evidence: `selection_handles_0.25x/1.0x/4.0x.png`.
- Severity: high.

## Zoom, tools, phone width, note overflow, cursors, live ink, design system, render loop

Verdict: fine across the board; each checked independently and held up.

- **Zoom** (`zoom_stress_0.25x/1.0x/4.0x.png`): stroke width and shape borders scale with zoom by design, drawn in world-unit coordinates; proportions stay sensible across all three captured zooms.
- **Selection handles at zoom** (`selection_handles_0.25x/1.0x/4.0x.png`): handles stay a constant on-screen size at every zoom, painted in screen space with no scale applied - see Cross-cutting.
- **Note overflow** (`note_overflow_hard_clip`): a note whose text is roughly double its box's capacity truncates with a trailing ellipsis at a word boundary, never mid-word - a prior silent `maxLines: 200` clip is already fixed per that function's own doc comment, and the screenshot confirms it holds.
- **Four tool states** (`canvas-tool-select/note/shape/eraser-*.png`): the active tool sits inside an outlined, tinted container distinct from every inactive tool's plain glyph, carried by shape and colour together, never colour alone.
- **Phone-width assembled pane** (`busy-phone-390-dark.png`, `busy-compact-599/600-dark.png`, `busy-phone-landscape-dark.png`): the dock collapses correctly at each breakpoint with nothing clipped and no overlap with the self bubble at the 599/600 boundary, consistent with the fix already recorded in CLAUDE.md for that band; the truncation banner and selection outline both render correctly at phone width.
- **Multi-user cursors** (`cursors_dark/light/true_black.png`): every cursor carries a filled name-label chip attached to the pointer, so identity reads from the name text first and colour second, legible against every background tested including true black.
- **Live ink vs. committed ink** (`live_ink_dark.png`): an in-progress remote stroke renders in the drawing author's own categorical colour rather than the finished-stroke colour, and growing-in-real-time is a strong non-colour cue on its own, so this is not a colour-alone violation - noted low severity only because a static image of a call (a recording, a screenshot) would lose that temporal cue with no third differentiator like reduced opacity to fall back on. Not concrete enough to require a fix.
- **Design-system conformance**: no emoji anywhere in these screenshots; cursor and object colours come from `AppCanvasColors.cursors`, a token-backed closed set, not literals; error banners use `AppErrorState`, the truncation banner uses `AppCallout`, the overflow menu uses `AppMenu`/`AppMenuItem`/`AppKbd` - no ad hoc chrome found.
- **Render-loop discipline**: every `ref.watch`/`ref.read` under `screens/canvas/` sits in ordinary widget build methods, gesture handlers, or the activity panel; none of it reaches `voice_canvas`'s painters or `CanvasSurface`'s paint path, which structurally cannot import Riverpod at all.
- **Nine of ten error states**, beyond the ones covered above, are distinct and specific: "That stroke was erased while it was being saved" (matches `PlaceError::Removed` exactly), "The canvas is not available in this channel" (see above), and the four image-paste failures (decode, upload, refused, catch-all) each fire at a genuinely different point in the same flow and are worded to match.

## Cross-cutting

The rasteriser paints a soft, translucent shadow as a hard, opaque black edge, a known limitation of the offscreen renderer used for this capture set.
Every `elevation_*` and hairline-dashing screenshot reviewed reads as one of those two known artifacts, not a new defect, and none is reported as one above.

The background grid is the finding worth escalating above everything else in this review: real, coded, documented, individually screenshot-tested in isolation, and never actually rendered in the shipped, assembled canvas pane, in any theme or scenario captured here.
It is a one-line class of fix, and it was invisible to every test in the suite except a pixel-level look at the assembled screenshots, because the one widget test that touches it checks widget ordering, not visibility.
Worth a general note for this codebase: "the painter is mounted in the right place" and "the painter actually paints" are different claims, and this package's own precedent elsewhere (`benchmark/paint_paths.dart`, the canvas op-clock index-plan tests) of reading real behaviour rather than trusting structure is exactly the discipline that would have caught this sooner.

The clear-canvas contradiction and the overflow-menu truncation were each found independently by two different lenses reading the same evidence from different directions - the strongest kind of finding in this set, since neither depends on one reviewer's judgment call.
The full-canvas "id is taken" wording is the opposite case: a genuine, recorded disagreement between a technically-accurate reading and a person-facing-clarity reading of the identical sentence, left unresolved here rather than forced to one verdict, because the simplest fix satisfies both readings anyway.

What held up, worth recording because a large area with nothing wrong is itself a claim worth checking:
selection handles stay a constant on-screen size across 0.25x, 1x, and 4x zoom, painted in screen space rather than scaled with content, so they remain grabbable-looking at every zoom tested;
overflowing note text truncates at a word boundary rather than mid-word;
all ten error states use genuinely distinct wording, with the two exceptions already covered above;
the four tool states are distinguishable by shape as well as colour;
no Riverpod call reaches the canvas paint loop anywhere in this package;
and the timeout freeze's copy correctly matches its narrow real scope - place, move, and reorder only - never claiming to cover erase or undo, which it does not freeze.
