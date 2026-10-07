# Screen inventory: personal settings, Space settings, and admin screens

Part of [screen-inventory.md](screen-inventory.md).
"Surfaces harness" = `client/packages/app/test/ui_snapshot_test.dart`. "Overlay harness" = `client/packages/app/test/ui_overlay_snapshot_test.dart`.

Governing rule for every gated screen below: `SpaceSettingsSection` (`widgets/space_settings_section.dart`) is the only in-UI entry point into every admin screen, and it hides the whole section (all three group cards, every row, no residual divider) when the caller holds none of `MANAGE_MESSAGES`, `CREATE_INVITE`, `MANAGE_ROLES`, `MANAGE_SERVER`, `MANAGE_CHANNELS`, `BAN_MEMBERS`.
Each row inside is separately gated on its own bit, so a caller with only `CREATE_INVITE` sees just "Invites."
None of the individual admin screens re-check the permission themselves if reached directly by route: there is no client-side 403/redirect/blank state, the screen just issues its request and the server refusal surfaces as that screen's own ordinary error state.

Four routed admin screens have **zero coverage in the surfaces harness**, confirmed by grep: `admin-categories` (`/settings/categories`), `admin-analytics` (`/settings/analytics`), `admin-removed-members` (`/settings/removed-members`), and `debug-log` (`/settings/debug-log`) are not keys in `_surfaces` at all. `debug-log` is additionally the one screen in this whole area gated by no permission at all, reachable by every signed-in user from Personal Settings, which makes it arguably the most-reachable, least-tested screen in the app.

## Space settings section variants

- **space-settings-hidden-no-bits** — the section is entirely absent under the "Space settings" app bar. Reach: hold none of the six gating bits. Coverage: none (harness fixture is presumably full-admin).
- **space-settings-partial-bits** — only some of the three group cards ("Moderation"/"Access"/"Configuration") and only some rows render. Reach: any single-bit-or-subset combination. Coverage: none.
- **space-settings-full-admin** — every group and row present. Coverage: covered (`space-settings` surface).

## Reports queue (`/settings/reports`, `MANAGE_MESSAGES`)

- **admin-reports-loading**, **-empty**, **-error-retry** — `AppAsyncView` states. Coverage: only `-empty` is covered (fake HTTP catch-all always answers `[]`); loading and error are not.
- **admin-reports-load-more-loading**, **-load-more-error**, **-load-more-button** — pagination footer states. Coverage: none.
- **report-card-message** vs **report-card-user** — two headline variants. Coverage: none (queue is always empty in the harness).
- **report-card-reporter-resolving**, **-reporter-deleted**, **-reporter-named** and **report-card-author-gone**, **-author-named** — label-resolution states, see the moderation doc for the full set.
- **report-card-quick-actions-full**, **-none**, **-jump-disabled** — permission- and reachability-dependent action rows; full detail in the moderation doc.
- **report-card-resolve-confirm**, **-dismiss-confirm** — verb-specific `confirmDangerousAction` copy. Coverage: none.
- **report-quick-action-delete-confirm**, **-remove-confirm** — per-action confirmations, own copy each. Coverage: none.
- **report-card-busy**, **-auto-resolved-on-success** — every button disabled mid-action; card disappears from the queue when a quick action closes the report as a side effect. Coverage: none.

## Invites (`/settings/invites`, `CREATE_INVITE`)

- **admin-invites-loading**, **-empty**, **-error-retry** — Coverage: only `-empty` is what the harness likely shows; not confirmed which of the three the fake API actually produces.
- **invite-create-idle**, **-submitting**, **-error**, **-created-callout** — inline create card, not a modal. Coverage: none.
- **invite-role-grant-picker-hidden** (no `MANAGE_ROLES`), **-loading-silent**, **-error**, **-empty-no-grantable-role**, **-populated** — five states, the loading one deliberately silent (no spinner) so the row does not appear to exist yet. Coverage: none.
- **invite-row-badge-revoked**, **-fully-used**, **-expired**, **-unusable-generic**, **-usable-no-badge** — badge precedence order: revoked beats used beats expired. Coverage: none.
- **invite-revoke-confirm** — per-row, busy + inline error on failure. Coverage: none.

## Roles (`/settings/roles`, `MANAGE_ROLES`)

- **admin-roles-loading**, **-empty**, **-error-retry** — Coverage: only `-empty` is likely; not confirmed.
- **role-card-administrator**, **-zero-permissions**, **-one-permission**, **-n-permissions** — four distinct summary-line phrasings. Coverage: none.
- **role-card-everyone-no-assign-delete** — the @everyone role's assign/delete icons are replaced by empty width-matched spacers rather than hidden outright. Coverage: none.
- **role-editor-sheet-create**, **-edit** — one sheet, two modes. Coverage: overlay harness covers one instance (unclear which mode).
- **role-editor-toggle-disabled-for-bit-you-lack** — a permission the caller doesn't hold renders dimmed with `onChanged: null`, present-and-disabled rather than absent — a deliberate exception to this codebase's usual "absent, not disabled" rule. Coverage: none (fixture user holds every bit).
- **role-editor-submitting**, **-error** — Coverage: none.
- **role-delete-confirm** — Coverage: none.
- **role-assign-sheet-loading**, **-error-no-retry** (plain text, no retry button, unlike most error states here), **-populated**, **-toggle-disabled-not-grantable** (every toggle disabled with "Needs permissions you do not hold"), **-toggle-error-banner** — Coverage: overlay harness covers only the populated default.

## Removed members (`/settings/removed-members`, `BAN_MEMBERS`)

- **admin-removed-members-empty**, **-populated**, **-error-retry** — Coverage: none, route absent from the surfaces harness entirely.
- **removal-card-with-reason**, **-no-reason** — Coverage: none.
- **removal-restore-busy**, **-restore-error** — "Let back in" has no confirmation dialog, unlike the removal action itself. Coverage: none.

## Channel permission overwrites (`/settings/permissions`, `MANAGE_ROLES` in the target channel)

- **admin-overwrites-blank** — persistent info callout plus "Choose a channel," nothing else. Coverage: covered (`admin-overwrites` surface, this exact blank state).
- **admin-overwrites-role-picked**, **-member-picked** - full `Perm.gridRows` list plus Clear/Set, after a target is chosen. Coverage: none.
- **overwrite-picker-sheet-channel** — no async states of its own. Coverage: overlay harness covers it.
- **overwrite-picker-sheet-role**, **-member** — each has loading/error(+retry text link)/empty/populated. Coverage: overlay harness covers only the populated default of each.
- **overwrite-allow-disabled-lacking-bit** — the "Allow" segment specifically is dimmed and inert when the caller lacks that bit themselves; Deny is always offered. One of the few deliberate disabled-not-absent cases. Coverage: none.
- **overwrite-set-confirm**, **-clear-confirm**, **-busy**, **-error**, **-success-toast** — success uses a `SnackBar` deliberately (non-error confirmation), failure uses inline `AppErrorState`. Coverage: none.

## Channel categories (`/settings/categories`, `MANAGE_CHANNELS`)

- **admin-categories-loading**, **-store-error-no-retry**, **-empty-with-caption** — reads the local drift store rather than a fresh REST call, so its top-level error state has no retry affordance at all. Coverage: none, route absent from the surfaces harness entirely.
- **category-create-idle**, **-error-banner** — Coverage: none.
- **category-card-rename-idle**, **-rename-reverted-on-failure**, **-delete-confirm** — reorder is worth calling out as **not existing** in this screen at all (no drag handle, no up/down control on `_CategoryCard`); if a reorder affordance exists it lives elsewhere (the channel rail), not here. Coverage: none.

## Custom emoji (`/settings/emoji`, reading needs no permission, writing needs `MANAGE_SERVER`)

- **admin-emoji-loading**, **-empty**, **-error-retry** — Coverage: only `-empty` likely; not confirmed.
- **emoji-upload-blank-hint**, **-unusable-name-error**, **-name-preview**, **-name-taken**, **-image-picked-preview**, **-submitting**, **-conflict-409** — the upload card's seven states. Coverage: none.
- **emoji-row**, **-delete-confirm** — Coverage: none.

## Space analytics (`/settings/analytics`, `MANAGE_SERVER`)

- **admin-analytics-off** — toggle card always renders; below it, `{"enabled": false}` carries no `stats` key at all (never computed, not merely hidden). Coverage: none, route absent from the surfaces harness entirely.
- **admin-analytics-on-populated**, **-toggling**, **-loading**, **-error-retry-preserves-stale-stats** — a failed retry deliberately keeps whatever stats were already on screen rather than blanking them. Coverage: none.
- **analytics-stat-tiles** — total messages/members/channels/attachment bytes. Coverage: none.
- **analytics-messages-by-day-chart-populated**, **-empty-history** (still renders the shell, "Total: 0") — Coverage: none.
- **analytics-active-hours-chart-populated**, **-no-messages-in-window** — Coverage: none.
- **analytics-memory-chart-insufficient-data** (distinct plain-card empty state, unlike the other two charts), **-populated** — Coverage: none.

## Debug log (`/settings/debug-log`, no permission gate, reached from Personal Settings > About)

- **debug-log-empty** — icon + "Nothing has gone wrong this session," Copy/Clear both disabled. Coverage: none, route absent from the surfaces harness entirely.
- **debug-log-populated-plain-entries**, **-expandable-entries-collapsed**, **-expandable-entries-expanded** — entries with a `detail` are `ExpansionTile`s. Coverage: none.
- **debug-log-severity-color-coding** — error/warning/info tones on the source label. Coverage: none.

## Personal settings (`/settings`)

- **personal-settings-nav-compact** — nav is the whole screen below 800px width, tapping a pane pushes a second screen with "Back to settings." Coverage: covered.
- **personal-settings-nav-wide-with-pane** — persistent 240px nav column beside the pane body at or above 800px. Coverage: covered, including the exact `settings-799`/`settings-800` breakpoint pair.
- **personal-account-section** — profile, presence status, avatar. See the overlays doc for the avatar crop sheet and the moderation doc for account deletion's confirmation.
- **personal-appearance-section** — theme choice.
- **personal-notifications-section** — push status row (registered/blocked/off, three tones), sound toggle, per-category preference sheet (All/Mentions-and-DMs/Nothing). Coverage: none.
- **personal-safety-devices-section** — device list, per-device sign-out (no confirmation, single tap), busy/error inline. Coverage: none.
- **personal-safety-blocked-section** — blocked list with resolved names, unblock (no confirmation). See the moderation doc.
- **personal-about-section** — links to the debug log above.

## Voice settings (a pane inside Personal Settings)

- **voice-settings-microphone-in-call**, **-not-in-call** — the live meter is replaced by an info callout when not in a call. Coverage: none.
- **voice-settings-device-picker-unavailable** — a permanent static callout, never a real picker in this build; no state variance. Coverage: none.
- **voice-settings-screen-share-quality** — three-way segmented control. Coverage: none.
- **voice-settings-sounds-join-leave**, **-call-ring** — two independent toggles plus a permanent ">8 participants" explanatory callout. Coverage: none.
- **voice-per-participant-volume-supported** (Android/iOS/macOS, shown in the member popover, not here), **-unsupported** (Linux/Windows/Web, absent not disabled) — lives in `member_profile_sections.dart`, not this screen. Coverage: none.
