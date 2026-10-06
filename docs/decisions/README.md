<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Decision records

One record per decision, numbered in the order they were written.
The status column is the start of each record's own `Status:` line; the record has the full text, including what is and is not built.
This index is written by hand from the records, so add a row when you add a record, using the next free number.

`scripts/lib/test_decision_index.py` fails on a record with no row, a number used twice, a row that links a missing file or the wrong number, and a first heading that does not start with the record's own number as `# NNNN - `.
Take the next free number from `origin/main` at the moment you open the PR, since two branches can claim the same one.

| Record | Title | Status |
| --- | --- | --- |
| [0001](0001-owner-decisions.md) | Owner decisions on the ten open planning questions | accepted |
| [0002](0002-architecture-followups.md) | Architecture follow-up decisions | accepted |
| [0003](0003-library-decisions.md) | Library and tooling decisions from the validation pass | accepted (technical) |
| [0004](0004-visual-identity-review.md) | Visual identity review | accepted |
| [0005](0005-threads.md) | Threads | built |
| [0006](0006-channel-categories.md) | Channel categories are containers, not the channel's type | accepted |
| [0007](0007-extensions-and-untrusted-execution.md) | Extensions, and why untrusted execution can only ever live behind one | proposed |
| [0008](0008-space-analytics.md) | Space usage analytics | built |
| [0009](0009-reactions-pins-polls-reconciliation.md) | The reconciliation debt reactions, pins and polls do not have, and would not need if they ever gained one | designed, not built |
| [0010](0010-canvas-media-tiles.md) | Canvas media tiles: camera and screen share as movable AR objects | accepted |
| [0011](0011-per-channel-permissions.md) | Per-channel permissions | built, 2026-08-09 |
| [0012](0012-desktop-window-shell.md) | Desktop window shell | built |
| [0013](0013-settings-container-system.md) | One container system for settings and administration | accepted |
| [0014](0014-canvas-video-subscription-culling.md) | Viewport-driven video subscription culling on the canvas | accepted, implemented |
| [0015](0015-moderation-audit-trail.md) | Moderation keeps its history in a log, not in the tables that hold current state | accepted, implemented |
| [0016](0016-message-deletion-has-no-hierarchy.md) | Message deletion has no hierarchy, and no appeal path exists in the product | accepted, implemented |
| [0017](0017-unified-canvas-items-and-context-menu.md) | One canvas item, one right-click menu | accepted; not yet built |
| [0018](0018-confirmation-toasts-and-why-errors-never-are.md) | Confirmation toasts, and why errors never are | accepted, implemented |
| [0019](0019-link-unfurling-and-ssrf-defense.md) | Link unfurling, and the SSRF defense it demands | accepted |
| [0020](0020-desktop-update-notifier.md) | The desktop update notifier is install-format aware | accepted |
| [0021](0021-modules-and-the-dock.md) | Modules and the Dock | accepted (implementation phased) |
| [0022](0022-module-extensibility-and-evolution.md) | Module extensibility and evolution | accepted |
| [0023](0023-mediated-host-capabilities.md) | Mediated host capabilities | accepted |
| [0024](0024-silent-sign-outs.md) | Silent sign-outs are diagnosed before they are fixed | accepted (diagnosis); remedy deferred |
| [0025](0025-update-strategy.md) | How every surface of slim-m gets its updates | accepted |
| [0026](0026-polyglot-code-runner.md) | One runner service for the common languages, modules for the odd ones | accepted |
| [0027](0027-module-scene-sound.md) | Module scene sound | accepted |
| [0028](0028-bot-accounts.md) | Bot accounts | accepted, implemented |
| [0029](0029-drafts-are-persisted.md) | Drafts are persisted, and are the one local-only table | accepted |
| [0030](0030-incoming-webhooks.md) | Incoming webhooks, and the authorship model they force | accepted |
| [0031](0031-bot-command-registration.md) | Bot command registration | accepted |
| [0032](0032-voice-participant-webhooks.md) | Voice participant events come from LiveKit webhooks, not client self-report | accepted |
| [0033](0033-notification-schedule.md) | The notification schedule: per-weekday hours, timezone-correct, with an off-hours policy | accepted |
| [0034](0034-read-state-across-devices.md) | Read state across devices: the marker is per account, and push consults it | accepted |
| [0035](0035-module-or-bot.md) | When something is a module and when it is a bot | accepted |
| [0036](0036-security-check-first-join-only.md) | The security check shows on first join only | accepted |
| [0037](0037-ephemeral-bot-messages.md) | Ephemeral bot messages | accepted, implemented |
| [0038](0038-module-caller-id.md) | A module is told an opaque caller id and nothing else | accepted |
| [0039](0039-bot-message-buttons.md) | Buttons on bot messages, and private answers to a press | accepted, implemented |
| [0040](0040-call-mini-player-and-pop-out.md) | Mini-player, desktop pop-out and phone picture-in-picture | accepted |
| [0041](0041-per-user-installs-and-signed-self-update.md) | Per-user installs and signed self-update | accepted |
| [0042](0042-encrypt-local-database.md) | Encrypt the local device database | accepted |
| [0043](0043-module-scene-timeline.md) | A scene declares its motion; the client plays it | accepted |
| [0044](0044-rich-presence.md) | Rich presence: what someone is listening to or playing | accepted |
| [0045](0045-bot-contributed-ui.md) | Menu entries and call controls a bot contributes | accepted, implemented |
| [0046](0046-more-than-one-module-source.md) | More than one module source | accepted |
| [0047](0047-call-dock.md) | The call dock | accepted; partly built |
| [0048](0048-totp-two-factor.md) | TOTP two-factor authentication | accepted |
| [0049](0049-per-channel-notification-behaviour.md) | a per-channel notification override decides the badge too | accepted |
| [0050](0050-watch-party-sync-authority-and-direct-play.md) | The watch party keeps its shared track and gains per-viewer direct play | accepted; stage 1 built |
| [0051](0051-who-reacted.md) | Who left a reaction is readable on request, never on the wire | accepted |
| [0052](0052-version-reports-claimed.md) | /version says whether the deployment is claimed | accepted |
| [0053](0053-custom-emoji-names-search-and-typed-shortcodes.md) | Custom emoji names, search, and what a typed shortcode does | accepted |
| [0054](0054-push-preview-default-on.md) | Push previews are an account choice, on by default | accepted |
| [0055](0055-member-nicknames.md) | An administrator can give a member or bot a space-local name | accepted |
| [0056](0056-activity-art-source-and-spotify-link-feedback.md) | Activity carries a source label and Spotify cover art, and Spotify linking reports what happened | accepted |
| [0057](0057-ios-background-modes.md) | iOS declares audio and voip, and constructs the PushKit registrar | accepted |
