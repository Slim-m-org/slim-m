# Every screen, reviewed by a panel

A per-screen improvement report over every screen in the product.
It was produced by rendering the whole app and putting each area in front of a panel of three specialists who looked at the same images independently.
509 images, covering 249 distinct screen states, across four capture harnesses, with three lenses reviewing each of the seven areas below.
Read `docs/reports/screen-inventory.md` first if you want the map of what exists; this is the judgement pass on top of it.

## How this was produced

`scripts/ui-capture.sh` renders the real app through four harnesses and writes the 509 images into `build/ui-capture/images/`, grouped into routed screens, overlays (sheets, dialogs, menus, popovers), the assembled canvas, and the canvas painters on their own.
Every routed screen is rendered at several viewports and in all themes, and the capture brackets the exact widths where a layout changes shape (467/468, 599/600, 799/800, 899/900, 999/1000), so a breakpoint is looked at from both sides rather than assumed.

Each area then went to a panel of three specialists who looked at the same images independently:

- **frontend** - layout at every viewport, design-system conformance, whether each state renders as itself, widget-structure smells in the source behind the screen
- **ux and accessibility** - copy, hierarchy, whether a state is a dead end, cues carried by colour alone, touch targets
- **backend and contract** - whether what a screen claims matches what the server actually does, checked against the handler and the schema rather than the label

A finding earns its place only if it names a concrete improvement, cites the image it was seen in, and points at a file.
"Nothing to change here" is recorded as a verdict rather than padded out.

## What this found

76 findings carry an explicit severity across the seven reports: 20 high, 37 medium, 19 low.
That count is a sum of what each report itself labels, not an estimate; the tally by area is in the table below.

Nothing in the product is broken outright.
Every one of the seven areas has at least one finding that would mislead or fail a real person, and the same missing piece of client architecture - no per-channel permission read - was independently rediscovered in five of the seven areas, which is the finding that most changes how the rest of this list should be read. That one is now closed; see the section below.

## The systemic finding - closed

**This was closed on main in PRs #522 and #523, under `docs/decisions/0011-per-channel-permissions.md`, and the record below is history rather than an open finding.**
All seven sites now read a per-channel permission, and `channelPermissionsProvider` (`client/packages/app/lib/src/features/channels/providers/channel_permissions.dart`) is the abstraction this section was written to ask for.
Verified against current source on 2026-08-18, site by site, not taken from the area reports' own strikethroughs.
Two of the files named below have also moved since: `channel_message_actions.dart` and `canvas_pane.dart` now live under `lib/src/screens/`.

It is kept because it is the clearest statement of why the seven were one bug, which is what decision 0011 was written from.

The client gated actions on the caller's deployment-wide base permissions (`GET /me`, `Store::base_permissions`), while the server authorizes the same actions per channel (`permissions_in_channel`, which folds in channel overwrites and, for a DM, an entirely different evaluator that never grants moderation bits to anyone).
This was found independently in seven places across five areas by three different backend passes, and each report names its own site by file and line:

1. **shell.md** - the DM/thread message-action menu (Pin, Delete) gates on `myPermissionsProvider` (`admin_providers.dart:28`), read by `channel_screen.dart`, against the server's per-channel `permissions_in_channel`, which never grants `MANAGE_MESSAGES` inside a DM at all.
2. **settings.md** - Space Settings' "Channel permissions" row is gated on the caller's deployment-wide `MANAGE_ROLES` (`space_settings_section.dart:100-105`), but the route it opens is gated per channel (`overwrites.rs:74-84`).
3. **voice.md** - the Eject-from-call button's `canEject` reads deployment-wide `mine.hasPermission(Perm.kickMembers)` (`member_profile.dart:297,301-305`), where the server's kick route checks `KICK_MEMBERS` per channel (`voice.rs:303-305,325-339`).
4. **overlays.md** - the message context menu's `messageActionsFor` (`channel_message_actions.dart:217-259`) computes Delete/Pin from the same deployment-wide provider, where the server authorizes per channel (`http/messages.rs:236-330`, `http/pins.rs:193-208`).
5. **overlays.md** - the canvas object context menu and "Clear canvas" read `canManage` from the deployment-wide `meProvider` (`canvas_pane.dart:369-370`), where the server evaluates `MANAGE_CANVAS` per channel (`http/canvas_ops_write.rs:83-90`).
6. **moderation.md** - the member popover's own Eject control reads the identical deployment-wide bit (`member_profile.dart:301-305`) against the same per-channel server route as site 3, found again here through the popover rather than the confirmation dialog.
7. **moderation.md** - the report card's "Delete message" button reads deployment-wide `mine.hasPermission(Perm.manageMessages)` (`report_card.dart:180-181`) against the server's per-channel check (`http/messages.rs:255-259`).

At the time of the pass there was no per-channel effective-permission provider anywhere in `client/packages/app/lib/src/providers/` - both shell.md and moderation.md confirmed this by grepping the whole client tree and finding nothing. `channel_permissions.dart` is that provider, added since.
So this is one missing abstraction, not seven bugs: every site above would close the same way, by reading a per-channel permission the way the server does instead of the flat bitmask off `GET /me`.

The sharpest instance was site 7.
A DM message report is a real, reachable item in the moderation queue by design, and for a DM channel the server's permission model structurally never contains `MANAGE_MESSAGES` for anyone, not even an administrator.
So a moderator opening a report about DM harassment saw "Delete message" rendered as an available, enabled button, and every tap against it failed.
`report_card.dart` now reads `report.channelPermissions`, the batched per-report field decision 0011 added.

None of the seven is a security hole.
The server re-authorizes and refuses every one of these requests correctly on its own, independent of what the client showed.
The cost is entirely on the other side: the client offers actions that are guaranteed to fail, and in the under-offering direction, hides actions the server would have honoured from a moderator who holds them only through a channel overwrite.

## The five worst individual findings

- **The canvas background grid has never actually rendered in the assembled pane, in any theme or scenario, since PR #505.** It paints correctly in every isolated painter fixture and in none of the 39 assembled screenshots; a bare `CustomPaint` with no child and no `StackFit.expand` collapses to zero size. Fixed in PR #515, at the widget rather than the call site, with a test that asserts the layer's real size rather than its position in a child list. [canvas.md](canvas.md)
- **The clear-canvas confirmation says "This cannot be undone" while the same client arms a working local undo for that exact action**, found independently by two different reviews reading the same dialog from different directions. [canvas.md](canvas.md), [overlays.md](overlays.md)
- **The report card's "Delete message" button was a guaranteed dead click on a DM harassment report** (closed, PR #523), offered as an available action for a permission no one can structurally hold in a DM, on exactly the report class this product's own moderation history went out of its way to make visible. [moderation.md](moderation.md)
- **The command palette overflows sideways off the phone viewport and ships visibly broken on real phone-width hardware** - it is the one overlay in the whole set that never adopted the shared bottom-sheet pattern every other sheet in the product uses. [overlays.md](overlays.md)
- **A thread panel gives no orientation once you are inside it**: no channel name, no parent message, just the word "Thread," the single biggest orientation gap found across the whole shell pass. [shell.md](shell.md)

## What the pictures found that tests could not

This is the class of defect the whole exercise existed to catch: something that passes every test in the suite and is obvious the moment a real screenshot is looked at.

- **A painter that is mounted correctly and never paints.** The canvas grid renders in every isolated `CustomPainter` fixture and in zero of the 39 assembled screenshots. The one test that touches it asserts the painter sits in the right position in `Stack.children`; it never asserts the painter has non-zero size or actually draws anything, which is exactly the gap between "mounted in the right place" and "paints." The painter fixture could not have caught it either, for a reason worth keeping: it calls `GridPainter.paint` directly against an explicit canvas size, with no widget layout involved at all, so that harness is structurally blind to a layout bug. [canvas.md](canvas.md)
- **Blank frames standing in for real states.** Space Settings' no-access screen renders a bare app bar over nothing, with no card and no explanation, reachable not only by a stray URL but by a permission being revoked while the screen is already open. [settings.md](settings.md) The canvas loading state is a flat rectangle with no spinner or skeleton, pixel-identical to what a broken canvas would look like. [canvas.md](canvas.md) The voice roster's genuinely-ambiguous "unknown" state renders `SizedBox.shrink()`, indistinguishable from a stalled load or a missing widget. [voice.md](voice.md)
- **A section header with nothing under it.** A moderator holding only `KICK_MEMBERS`, looking at an already-timed-out member with no shared call, sees a "MODERATION" header followed by four conditions that all evaluate false, found independently by two lenses at the identical line. [moderation.md](moderation.md)
- **A confirmation that contradicts its own undo.** The clear-canvas dialog's "This cannot be undone" sits next to a working `_EraseEntry` undo stack wired to the same controller instance visible in the same view, no intervening step or permission change required. [canvas.md](canvas.md)

## What the review found about the evidence itself

A screenshot is only evidence if the harness that produced it is honest, and this review found several places where it was not, each failing silently rather than loudly.

- **The harness never loaded a colour emoji face at all, so every reaction chip in all 509 images rendered as a missing-character box.** `loadRealFonts` pinned IBM Plex Sans and Mono, both Lucide faces and MaterialIcons, and nothing else; `AppFonts.emoji` names three system faces, none of them a file this repo ships, so none resolved. Emoji here are user content rather than chrome, which is what makes this more than cosmetic: a reviewer reading those chips reported a defect the product does not have, and that is exactly what happened. Fixed in PR #512, which looks the face up across the paths distributions actually install it at and warns by name when it finds none, rather than skipping silently. A later pass briefly saw the boxes again and attributed them to a concurrent capture race; it was reading the directory mid-regeneration while the fix was being applied, and re-checked correctly a moment later. [shell.md](shell.md)
- **The plain voice join-arrival surface captured as a blank pane below its header**, across every viewport and theme sharing that fixture, flagged independently by two lenses. It went through the ordinary surface loop with no controller override, so it raced `VoiceScreen`'s real auto-join against a fixture with no SFU behind it and wrote whatever was on screen mid-transition. Checked specifically, and it is not a reachable product state: `VoiceController.join` catches every failure mode and always lands on a terminal state carrying a real message. Fixed in PR #513 by pinning the connecting state, which is what that surface was always there to prove across its nine breakpoints. [voice.md](voice.md)
- **The offscreen rasteriser paints a soft, translucent shadow as a hard, opaque black edge**, and this had already misled one earlier sign-off pass before it misled two more lenses in this review, on the call dock's own shadow and again on every `elevation_*` canvas screenshot. It was documented all along, in the visual test support file of a different package from the harness that produces these images, and in a caveats block on the generated gallery page that reviewers never open because they read the PNGs directly.
PR #514 moved it to where a reader actually meets it, and it is repeated here for the same reason. [voice.md](voice.md), [canvas.md](canvas.md), [overlays.md](overlays.md)
- ~~**Two fixtures invent copy the server never sends.** One shows "invites are disabled here" for a check route that has no code path producing that message at all; the other shows "password must be at least 8 characters" where the real server string is "password must be 8 to 1024 characters." Neither is a wire-contract bug a user would hit - the client's generic error mapping is correct regardless of the exact string - but both risk being read as documentation of real copy, and nothing guards either string against drift.~~ Both fixture strings fixed 2026-08-10; the drift guard itself (a shared JSON fixture both the Rust and Dart sides read, `mention_charset_cases.json`'s own shape) landed 2026-08-11. [onboarding.md](onboarding.md)
- ~~**Two byte-identical report-card screenshots mean one state was never actually verified.** `report-card-no-quick-actions-desktop.png` and `report-card-reporter-resolving-desktop.png` are the same image, confirmed by md5sum, because both underlying tests build the same harness with no `profiles` map. The "denied by permission" report-card state has therefore never been checked separately from "still loading."~~ Fixed 2026-08-10: the two fixtures are distinct now (`report-card-reporter-resolving-desktop` carries real permissions and an empty `profiles` map; `report-card-no-quick-actions-desktop` carries none), confirmed distinct by md5sum, not merely by re-reading the test source. [moderation.md](moderation.md)

## What held up

A review that only lists faults is not an honest picture of the product, so this is what came back clean under adversarial reading rather than a passing glance.

- The TOFU first-connect and identity-changed screens are unanimous across all three lenses with no findings at all: correct security framing, amber for routine and red for a real identity change, confirmation gated behind an explicit checkbox rather than a single tap. [onboarding.md](onboarding.md)
- The three-way distinction between catching-up, genuinely-empty, and offline-empty transcript states is structural, driven by a real three-value enum a single widget switches on, not three labels sharing one signal that could quietly collapse into each other. [shell.md](shell.md)
- Admin categories, and the analytics screen's own defence against reading as per-member surveillance, have no findings from any of the three lenses; role and channel matching throughout the admin surface is by id, never by name, correctly given that role names are not unique in the schema. [settings.md](settings.md)
- Mic, camera, share and speaking state change icon shape everywhere they appear, never colour alone, and a `listEquals` gate on the voice roster stops LiveKit's continuous audio-level stream from forcing a full rebuild on every frame. [voice.md](voice.md)
- Selection handles hold a constant on-screen size across a 0.25x-to-4x zoom range, note text truncates at a word boundary rather than mid-word, and no Riverpod call reaches the canvas paint loop anywhere in the package. [canvas.md](canvas.md)
- All eleven `confirm-*` dialogs share one component with zero hand-rolled `AlertDialog`s anywhere in the app, and danger is outlined rather than filled in every single confirmation and context menu checked. [overlays.md](overlays.md)
- The blocked-DM composer shows nothing block-aware before a send is attempted, so there is no leak at the affordance level; report and block remain one shared implementation called identically from every site that needs them. [moderation.md](moderation.md)

## Areas

| Area | Screens | Report | State |
| --- | --- | --- | --- |
| Onboarding and server connection | onboarding, sign-in, invite and manual-server dialogs, the nine submit failures, TOFU and identity, probe notices | [onboarding.md](onboarding.md) | Strong: TOFU and identity are the best work in the review; the recurring gap is raw server error text reaching the screen unedited. |
| Shell and messaging | channel, thread, DM, rail states, transcript empty/offline/catching-up, no-channel-selected | [shell.md](shell.md) | Reads well at every width; the worst gaps are a thread with no orientation and a rail-restore icon that fails contrast by half. |
| Settings and administration | personal settings, Space settings and its access tiers, roles, invites, overwrites, categories, emoji, reports, analytics, removed members, debug log | [settings.md](settings.md) | Solid throughout, no high-severity finding; two blank-state gaps and one row that offers an action a channel overwrite can refuse. |
| Voice | join preview, connecting, in-call and its variants, rejoin, switch prompt, who-is-here, DM call | [voice.md](voice.md) | Correct core call surface; the sharpest gaps are a blank ambiguous-roster state and an eject button scoped to the wrong permission. |
| Canvas | the pane, the combined call-and-canvas surface, tools, errors, activity log, and the painters | [canvas.md](canvas.md) | The strongest and weakest area at once: careful error-state work sitting on a genuinely invisible background grid and a self-contradicting undo dialog. |
| Overlays | sheets, pickers, confirmations, context menus, the command palette | [overlays.md](overlays.md) | Confirmations are the most consistent surface in the product; the picker sheets and the command palette are the least, with the palette shipping broken on phone. |
| Moderation and safety | member popovers and their permission tiers, report cards, safety notices, blocked-DM notices | [moderation.md](moderation.md) | Careful, honest copy nearly everywhere, undercut by a report card that can offer a delete action guaranteed to fail on exactly the reports it exists to surface. |

## Reading a finding

Severity is about what it costs the person using the product, not how hard it is to fix.

- **high** - the screen misleads, strands, or is unusable at a viewport somebody really has
- **medium** - the screen works and something about it is worse than it needs to be
- **low** - polish, consistency, or a thing worth knowing before the next change here

Anything marked **suspected** was reasoned from the image alone and not confirmed against source; treat it as a lead rather than a finding.
