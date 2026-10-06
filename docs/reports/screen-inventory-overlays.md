# Screen inventory: overlays, dialogs, sheets, menus, confirmations

Part of [screen-inventory.md](screen-inventory.md).
"Overlay harness" = `client/packages/app/test/ui_overlay_snapshot_test.dart`, which drives 21 named overlays open through their real entry points at desktop and phone width, dark theme only, each as one fixed instance.
See [screen-inventory-moderation.md](screen-inventory-moderation.md) for the moderation-specific variants of the member popover, report card, and blocked-DM notice.

## The 21 harness-covered overlays, and what each variant they show is

Each of these opens with the harness's own fixed parameters; only the generic instance below is captured, never a real-app variant.

- **confirm-dialog** — generic yes/no via `confirmDangerousAction`. Harness shows the delete-account copy specifically. No busy/error of its own; the caller runs the real request after it closes.
- **report-dialog** — the compose sheet only, generic "this message" label. Submission itself is not captured.
- **create-channel-sheet** — `initialKind: 'text'`. The `voice`-kind initial variant is not captured.
- **manage-channel-sheet**, **pinned-messages-sheet**, **member-roles-sheet**, **role-editor-sheet**, **avatar-crop-sheet**, **whats-new-sheet**, **member-profile-popover**, **command-palette**, **composer-actions-sheet**, **camera-source-sheet**, **screen-source-sheet**, **emoji-picker-sheet**, **space-emoji-sheet**, **channel-picker-sheet**, **role-picker-sheet**, **member-picker-sheet** — one fixed instance each; variants below.

## `confirm-dialog` variants beyond the generic delete-account instance

16 call sites total. Coverage for all of the below: none beyond the one generic instance the harness renders.

- **confirm-delete-message**, **confirm-delete-reported-message**, **confirm-delete-emoji**, **confirm-delete-category**, **confirm-delete-role** — five delete confirmations, each its own copy.
- **confirm-clear-canvas** - copy names no count, since the pane only holds part of the canvas; failure routes to the canvas pane's own `_error` field, not `AppErrorState`/SnackBar.
- **confirm-set-overwrite**, **confirm-clear-overwrite** — see the settings doc.
- **confirm-eject-from-call**, **confirm-remove-from-space** — both close the popover before the async call, so failure is a legitimate `SnackBar` per this codebase's own stated exemption (surface already gone).
- **confirm-revoke-invite** — see the settings doc.
- **confirm-resolve-report**, **confirm-dismiss-report** — verb-parameterised.
- **Destructive actions with no confirmation at all**, worth capturing precisely because their absence is the notable thing: revoke device/session (single tap), remove avatar (single tap), unblock (undo-friendly, no confirm by design), timeout/lift-timeout (lapses on its own), canvas object delete and clear-undo (reversible via undo stack), leave call/hang up (rejoin any time).

## Context menus and popovers (none in the 21; all interaction-only, none captured)

- **message-context-menu--own**, **--others-plain-member**, **--others-manage-messages-holder**, **--in-thread** — item set gated by authorship, `MANAGE_MESSAGES`, and whether the channel is itself a thread.
- **channel-row-context-menu--plain**, **--manage-channels-holder** — "Manage channel..." item conditional.
- **dm-row-context-menu--plain**, **--blocked** — Report/Block vs Report/Unblock.
- **member-row-popover** — see the moderation doc for the full permission-combination matrix; the overlay harness's fixed instance exercises exactly one combination.
- **canvas-object-context-menu--own**, **--manage-canvas-other** — see the canvas doc.
- **canvas-overflow-menu** — see the canvas doc; not in the 21, no `show*` entry point, unreachable by this harness's mechanism at all.
- **space-menu-button** — chevron menu, "Add channel"/"Add category" gated on `MANAGE_CHANNELS`, hidden entirely when Space settings isn't reachable at all.
- **presence-menu** — status picker (Online/Away/Do not disturb/Appear offline) from the rail footer avatar.
- **personal-space-menu** — structurally similar `OverlayPortal` menu, not independently inspected in full.
- **context-menu-keyboard-trigger** — the Menu key / Shift+F10 route into any `ContextMenuRegion`, an alternate trigger rather than a distinct overlay; the harness only calls `show*` functions programmatically, never this route.

## What's-new sheet variants

- **whats-new-backlog-null-lastseen** — full backlog, device predates the feature. The harness's fixed call is content-representative of this but bypasses `WhatsNewController._check()`'s own decision logic entirely (calls `showWhatsNewSheet` directly).
- **whats-new-rebaseline-frozen-constant** — `lastSeen == '0.1.0'` (the historical frozen value) silently re-baselines and shows nothing at all; a "sheet does not open" branch, not itself a visual state, unit-tested elsewhere but not at the UI level.
- **whats-new-incremental** — only entries newer than a real `lastSeen`. Not reproduced by the harness.
- **whats-new-gate-wiring** — `widgets/whats_new_gate.dart` is the real production trigger; never exercised (the harness calls `showWhatsNewSheet` directly instead).

## Command palette states

- **command-palette-empty-query** — quick actions only. Coverage: none beyond the harness's own default-open state.
- **command-palette-results** — channels/DMs, members, server-side FTS message results. Coverage: none.
- **command-palette-blocked-author-filtered** — message results drop entries from a blocked author, logic-level, no dedicated visual proof. Coverage: none.
- **command-palette-message-search-error** — referenced alongside the report-reachability check; not independently confirmed. Flagged as uncertain.

## Emoji and composer sheets

- **emoji-picker-sheet--catalog-tabs** (harness default), **--search-active**, **--search-empty** — Coverage: only the default tabs state.
- **space-emoji-sheet--loading**, **--error**, **--empty**, **--populated** — the harness's fixed call lands on whichever the fake fixture happens to answer; not confirmed which. Coverage: at most one of four, uncertain which.
- **avatar-source-sheet** — Photo library / Browse files, not in the 21, no top-level `show*` function. Coverage: none.
- **composer-actions-sheet--paste-available** — the harness passes `canPasteImage: Future.value(false)`, so the "Paste image" row never renders; the true variant is uncaptured.

## Sheets not in the 21 at all

- **poll-composer-sheet** — composer "Create a poll" action, 2-4 validated option fields.
- **canvas-note-sheet** — see the canvas doc.
- **edit-display-name-sheet** — Personal Settings.
- **invite-role-grant-picker** — see the settings doc.
- **onboarding-server-picker-sheets** (x2) — see the onboarding doc (the invite and manual-server dialogs, both `showAppSheet`-based).
- **settings-select-row-generic-picker** — a generic single-choice sheet reused across several settings rows (theme, screen-share quality, notification preference); each concrete instantiation is a distinct effective overlay content-wise, none captured.
- **role-assign-sheet** — see the settings doc.

## Remaining `SnackBar` sites (post-audit; PR #132 ("27 sites") reduced to a small, deliberate allowlist)

Each of these is legitimate per this codebase's own stated rule (a still-mounted persistent surface must use `AppErrorState`; a `SnackBar` is only correct once the triggering surface has already closed): debug log's "copied" confirmation, `channel_message_actions.dart`'s shared post-menu-close failure helper, invite code "copied" confirmations, channel-overwrite **success** toasts (failure is already inline elsewhere), member-popover eject/remove failures (popover closed first), a jump-to-message failure, and the shared `safety_actions.dart` report/block/unblock result sentence.
None of the remaining sites catch an exception directly on a surface that is still mounted, which is the shape the original 27-site regression had.
