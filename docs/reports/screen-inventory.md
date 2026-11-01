# Screen inventory: every screen and state, for the screenshot pass

This is the list, not the screenshots.
It was built by reading the client source and the two existing snapshot harnesses, not from memory, per the owner's own instruction that the hard part is the states reachable only from a combination of conditions.
Nothing here has been fixed and no screenshots were taken; this document is the deliverable.

## How it is organized

Split into one file per area, each staying well under the project's 300-line soft budget.
Capture in roughly this order, since each area builds on the last (a signed-out state before a signed-in one, a plain channel before a permission-gated variant of it):

1. [screen-inventory-onboarding.md](screen-inventory-onboarding.md) - onboarding, sign-in/create-account, server identity (TOFU), 48 bullets covering roughly 60 distinct states.
2. [screen-inventory-shell.md](screen-inventory-shell.md) - home shell, channel rail, no-channel-selected, text/voice/DM/thread conversation panes, member pane, 65 bullets covering roughly 80 distinct states.
3. [screen-inventory-settings.md](screen-inventory-settings.md) - Personal Settings, Space Settings, and all nine admin screens, with the permission-gating rules that apply to every one of them, 61 bullets covering roughly 90 distinct states.
4. [screen-inventory-voice.md](screen-inventory-voice.md) - voice calls, both channel and DM, connected and non-connected, 37 bullets covering roughly 45 distinct states.
5. [screen-inventory-canvas.md](screen-inventory-canvas.md) - the Voice Canvas, standalone and combined with a call, 43 bullets covering roughly 55 distinct states.
6. [screen-inventory-overlays.md](screen-inventory-overlays.md) - every dialog, sheet, popover, context menu, and confirmation, including the 21 the existing overlay harness already opens and the variants it does not, 40 bullets covering roughly 55 distinct states.
7. [screen-inventory-moderation.md](screen-inventory-moderation.md) - blocking, timeouts, reports, removal, and the permission-combination states these produce on top of screens listed elsewhere, 34 bullets covering roughly 40 distinct states.

Total: roughly 328 bullets naming on the order of 425 individually addressable states (some bullets name a short family of 2-4 closely related states in one line to save space; each is still individually reachable and worth its own frame if time allows).

## Reading an entry

Every state carries a stable kebab-case id (usable as a filename), a one-line description, exactly how to reach it, whether an existing harness already renders it, and a mobile-vs-desktop note where one applies.
Two harnesses exist and are referred to by name throughout:

- **Surfaces harness** — `client/packages/app/test/ui_snapshot_test.dart`. Renders named routes at a matrix of viewports and both themes via `scripts/ui-snapshots.sh`. Its `_surfaces`/`_canvasSurfaces`/`_voiceCallSurfaces` maps are the ground truth for what it covers; anything not a key in one of those three maps has zero coverage from it, full stop.
- **Overlay harness** — `client/packages/app/test/snapshots/ui_overlay_snapshot_test.dart`. Opens 21 named overlays through their real `show*` entry points at two viewports, dark theme only.

"Coverage: none" means literally that: nothing in either harness renders it today, so a screenshot of it has to be captured by hand, either by driving the real app or by writing a one-off fixture the way the harnesses already do.
"Coverage: covered" means the named surface entry renders it, though not necessarily every combination within it — read the entry's own note, since several "covered" surfaces render only one of several sub-states a route can be in.

## The four routed screens with zero harness coverage, named once here because they recur across the settings file

`/settings/categories`, `/settings/analytics`, `/settings/removed-members`, and `/settings/debug-log` are registered in `router.dart`, reachable in the running app, and **absent from `ui_snapshot_test.dart`'s `_surfaces` map entirely** — confirmed by grep, not inferred.
`/settings/debug-log` is additionally gated by no permission at all, which makes it the single most-reachable, least-tested screen found in this pass.

## The single highest-value gap to close first

No surface anywhere forces both `canvasOpenProvider` open and `voiceControllerProvider` connected on the same channel at once.
The surfaces harness's `canvas-voice` entry looks like it should be this combination by name, but reading `ui_snapshot_test.dart` shows it only forces the canvas open — it applies no voice override, so the combined call-and-canvas dock, and every canvas-camera-bubble state that depends on live call participants, most likely never renders in either harness today.
See [screen-inventory-canvas.md](screen-inventory-canvas.md) for the detail.

## Hardest states to actually reach for a screenshot

In roughly descending order of effort, independent of which area file they live in:

1. **The combined call-plus-canvas dock and canvas camera bubbles** — needs a real or forced-fixture voice connection and an open canvas in the same channel simultaneously; no existing harness combination does this.
2. **`dm-blocked-by-them-invisible`** — has no visible signal by design (the client only ever checks its own block list), so "capturing" it means screenshotting an ordinary-looking composer and a subsequent failed-send row, with a caption explaining why, since the screen itself carries no marker.
3. **`voice-live-call-discloses-hidden` vs. `voice-roster-preview-hides-hidden`** — the same hidden person needs to be shown twice, once absent from a pre-join roster and once present in a joined call roster, to demonstrate the asymmetry at all.
4. **Report queue states with a real permission mix** (`report-card-jump-unreachable`, `report-card-no-quick-actions`, `report-queue-scope-excluded`) — need a report fixture seeded with specific channel/permission combinations; the real queue is empty in every current test fixture.
5. **The TOFU identity-changed screen** — needs a pinned key already stored for an address, then a second connection to that same address answering with a different key; not reachable by any single form submission.
6. **`member-popover-admin-containment-gap`** — needs a target account whose granted permissions genuinely exceed the moderator's own, arranged deliberately, to show the row-present-then-fails-on-tap sequence.
7. **The four uncovered admin routes plus the "genuinely empty"/"still catching up" transcript trio** — not hard individually, just currently unexercised by anything, so each needs its own fixture from scratch.

## Believed but not pinned down

Kept honest and separate per the task's own instruction, rather than folded into the lists above as settled fact.

- **Whether `history-top-more` or `channel-start-header` actually renders for the surfaces harness's `c-general` channel.** Both are plausible outcomes of `ChannelHistory.atStart` resolving one way or the other during the harness's two settle-pumps; this was not confirmed by instrumenting a real run, only reasoned about from the source.
- **Whether the surfaces harness's `channel`/`voice` fixture ever produces a positive `rail-channel-row-unread-badge` delta or an `unread-divider-new`.** Depends on the exact seeded `cursor`/`lastReadSeq` values in the fixture data, which were read but not traced through the unread-computation logic with full confidence.
- **Which of the four `space-emoji-sheet` states (loading/error/empty/populated) the overlay harness's fixed call actually lands on.** Depends on what the fake HTTP client's catch-all answers for that specific provider, not confirmed.
- **Whether `command-palette-message-search-error` (a 403 on server-side FTS search) is genuinely reachable client-side, or only ever a theoretical case the code defends against.** One agent's research flagged this from a doc comment reference rather than tracing the actual call path end to end.
- **Whether the personal composer client-side disables itself while the local user is timed out**, versus relying entirely on the server refusing the send and the client rendering a generic failed-message row. `composer.dart` itself was not read in full during this pass; this is inferred from the absence of a grep hit for `timedOutUntil`/`TimeoutDeny` in the widgets that were read.
- **Whether a "restore canvas clear" control exists anywhere in the client UI.** The reviewed canvas files show no such affordance beyond the activity log's descriptive text for a `restore` op, but not every one of the roughly 40 canvas source files was read in full, only the interaction-heavy ones.
- **Whether the router's older documented bug ("a revoked session drops to bare onboarding, losing the server address") is actually fixed.** Reading `router.dart` today shows logic consistent with it being fixed (a remembered server routes to sign-in, not onboarding, regardless of why the session ended), matching CLAUDE.md's own later note that it was fixed 2026-07-28 — but this was not verified against a live revoked-token scenario in this pass, only against the redirect logic in isolation.
- **The exact permission grant the surfaces harness's fixture account holds**, referenced repeatedly across the settings and canvas files (e.g. whether "Clear canvas" or the manage-channel kebab is genuinely proven present because the fixture holds every bit, versus merely assumed to). Treated throughout as "the fixture user holds broad/admin-like permissions," which is very likely true from context but was not traced to one authoritative line.
