# 0018 - Confirmation toasts, and why errors never are

Date: 2026-08-25
Status: accepted, implemented

## Context

Backlog #136 asked for proper toast notifications.
PR #851 added the infrastructure: `AppToast` in the design system (`client/packages/design_system/lib/src/components/surfaces/toast.dart`), the `ToastsController` / `toastsProvider` queue (`client/packages/app/lib/src/providers/toasts.dart`), and `ToastOverlay` (`client/packages/app/lib/src/widgets/toast_overlay.dart`).
PR #859 then moved the app's genuine success confirmations onto it.

## Decision: toasts carry transient success/info only, never a failure

`AppToastSeverity` has three members: `success`, `info`, `warning`.
There is no `error` member, and there will not be one.

The reasoning is written into `toast.dart`'s own doc comment: this app's error grammar holds that a failure is a state, not an event.
A failure belongs at the point of the action and stays until something changes it (`AppErrorState`), never carried away on a timer.
A toast is the opposite shape on purpose: it is for the things that genuinely are events and are fine to miss entirely if the reader looks away for four seconds, such as "Copied," "Saved," or an invite code put on the clipboard.

This is enforced, not just documented.
`scripts/check-error-surface.py` fails a PR that catches an API failure and surfaces it through a SnackBar instead of `AppErrorState`; routing a caught error through a toast would fail the same gate for the same reason, and there is no severity value that would even let a call site try.

Presentation follows the same restraint.
The overlay is mounted once by `appChromeBuilder`, above the routed tree so a toast floats over a dialog, a sheet, or the title bar rather than inside whatever surface fired it, and it auto-dismisses on a per-toast timer (four seconds, `ToastsController.defaultDuration`) with a cap of four stacked at once so a burst cannot bury the screen.
Placement answers the same width question every other surface in this app answers: bottom-right on a wide window, where there is a pointer to dismiss with and room to spare, and top-center on a phone, where the thumb sits far from the top and a bottom toast would land under the composer.
The card itself is outlined rather than filled, following `AppErrorState`'s own convention: a hairline and a leading glyph in the severity tone over the ordinary raised surface, legible without being the loudest thing on screen.

## The rollout: which sites moved, and which deliberately did not

`showAppSnackbar` (`client/packages/app/lib/src/widgets/app_snackbar.dart`) mixed two different things at its call sites before this: a genuine success confirmation, and a failure sentence, sometimes both at once (a call site that shows `failure ?? succeeded`).
PR #859 split that mix rather than leaving it, because the two halves now belong on different surfaces under the grammar above.

Six sites carried a success-or-neutral message with no failure branch, and moved to `toastsProvider`:

- `debug_log_screen.dart` - a debug log copied to the clipboard.
- `admin/channel_overwrites_screen.dart` - an overwrite set, and an overwrite cleared (two call sites).
- `admin/invites_screen.dart` - an invite code copied, and an invite revoked (two call sites).
- `personal_space_menu.dart` - a personal space removed from the list (removed since, see the update below).

Seven sites carried a failure sentence, including the ones that pick between a failure and a success string with one call, and stayed on `showAppSnackbar`:

- `screens/channel_message_actions.dart` - two call sites, both failure-only.
- `widgets/forward_message.dart` - one call site, `failure ?? succeeded` at the time.
- `widgets/member_profile.dart` - two call sites, both failure-only.
- `widgets/message_jump.dart` - one call site, failure-only ("Could not find that message").
- `widgets/safety_actions.dart` - one call site, `failure ?? succeeded`.

**Update, forwarding's redesign (the same change that gave forwarding its attachments and its picker's UI):** `forward_message.dart` moved off this list.
Its picker used to pop the destination sheet on tap and only find out afterwards whether the send worked, which was exactly the "surface already closed" case `safety_actions.dart` still is - nothing left to hold a durable failure in, so `failure ?? succeeded` on one `showAppSnackbar` call was the least-bad option.
The redesign keeps the sheet open through the send instead, so a failure now renders as an inline `AppErrorState` in the picker itself (retryable, dismissible) rather than sharing a surface with success at all.
That leaves the success path with no failure branch tied to it, the same shape the six sites above already had, so it now fires through `toastsProvider` (`AppToastSeverity.success`) instead of `showAppSnackbar`.
`safety_actions.dart`'s sites did not change: a member popover and a report dialog still close before their request answers, with nothing to hold a failure in the way the forward picker now does.

The mixed sites were not split into a toast half and a SnackBar half.
Routing only the failure branch through `showAppSnackbar` while its sibling success branch went through a toast would leave one call site with two different confirmation mechanisms for the same action, chosen by which string happened to be non-null - worse than the single mechanism it replaced.
A site only moves once its success path has no failure branch to keep it tied to the SnackBar.

`showResolvedSnackbar` was removed in the same change: its one caller (`personal_space_menu.dart`) then read the toasts provider directly through the container it captured before its own await, so the helper had no remaining reason to exist.

**Update, personal space row removed:** `personal_space_menu.dart` and `personal_space_row.dart` were deleted in 0.130.0 (#2412), so the personal space toast above no longer exists.

## Reading this against the surface taxonomy

`docs/design/desktop-vs-mobile.md` rule 6 puts "confirmations" and "toasts" in the same bucket as the transient, unrequested-status surface, and says plainly: "Snackbars/toasts are for confirmations only, never for errors."
That rule is what this record makes concrete in code, and the "never a toast for an error" line in the doc's own never-rules is what `check-error-surface.py` and `AppToastSeverity`'s missing `error` member both exist to guarantee.

The doc's taxonomy does not distinguish two shapes of confirmation that this rollout runs into.
The ordinary Material pattern named "snackbar" - and every one of the fourteen call sites `showAppSnackbar` was standardizing before this rollout - is really a *confirmation with an optional undo action*, the surface reached for after a destructive act so the person who triggered it has a few seconds to take it back.
`AppToast` is not that.
It has a message, a severity, and a dismiss; there is no action slot, and nothing in `ToastsController.show` accepts one.
Every site this rollout moved was a plain confirmation with nothing to undo (a copy, a set, a removal already final), so the gap did not surface this time.
It will the first time a real delete-and-undo confirmation is proposed for a toast, because "the confirmations surface" reads as one thing in the design doc and is actually two in the code.

## Open follow-up

Nothing in this client currently fires a delete-and-undo style confirmation through either path; the closest precedent, canvas undo, lives in the right-click menu per 0017, not in a toast or a SnackBar.
When one is proposed, it needs an explicit decision rather than falling to whichever path a call site's author reaches for first:

- Give `AppToast` an optional action slot (a trailing "Undo" affordance next to dismiss), extending the transient-confirmation surface to cover it, or
- Route that specific case through a proper snackbar-with-undo - `showAppSnackbar` extended with an action, or a new surface - and keep `AppToast` action-free on purpose.

Either is defensible; what is not defensible is answering it by precedent, because the six sites this record ships do not set one.
None of them had anything to undo, so nothing here decides which way an undo-bearing confirmation should go.

## Alternatives considered

**Give every confirmation a severity that includes error, and let `AppToastSeverity` carry failures too.**
Rejected outright.
This is the one alternative the error grammar does not allow: a failure that can time out and disappear contradicts `AppErrorState`'s whole premise, that a failure is a durable state attached to what failed rather than an event a reader might miss.
`check-error-surface.py` exists specifically to keep this from regressing back in, having already regressed three times by the project's own history.

**Split every mixed `failure ?? succeeded` site into two calls, one toast and one SnackBar, chosen at runtime by which branch fired.**
Rejected for the reason given above: it leaves a single user action wired to two different confirmation mechanisms depending on outcome, which is more inconsistent than the one mechanism it would replace, not less.

**Migrate all fourteen original `showAppSnackbar` sites to toasts and retire the SnackBar path entirely.**
Not viable while any of them carries a failure sentence, which seven still do; retiring the SnackBar path would either strand those seven with no surface or force failures through a toast, both of which the error grammar rules out.

**Do the full split in the same change that added the toast infrastructure (PR #851).**
Deliberately deferred to a second, focused pass (PR #859).
`showAppSnackbar` carried both successes and failures at different sites when the toast layer landed, so splitting success-to-toast from failure-stays-put touches the error grammar itself and was kept separate from standing up the plumbing, rather than folded into one larger change.
