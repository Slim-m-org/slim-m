// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Acting on one member, from the row's own context menu.
///
/// Split out of `member_pane.dart`, for the same reason
/// `channel_message_actions.dart` was split out of `channel_screen.dart`:
/// both need a [BuildContext] to put a snackbar in front of somebody, which
/// is not something the pure roster/presence layer in
/// `providers/member_presence.dart` needs at all.
///
/// The actions themselves live in `safety_actions.dart` and are shared with the
/// message context menu; these two are the member row's names for them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;

import '../providers/member_moderation_error.dart';
import '../providers/dms.dart' show openDirectMessage;
import '../providers/member_presence.dart' show membersProvider;
import '../providers/notification_schedule_controller.dart';
import '../providers/providers.dart';
import '../routing/routes.dart';
import 'app_snackbar.dart';
import 'confirm_dialog.dart';
import 'run_guarded.dart';
import 'safety_actions.dart';

/// Files a report against a member, from the row's context menu.
///
/// Takes a [ProviderContainer] rather than a [WidgetRef] for the same reason
/// `safety_actions.dart` does: the caller dismisses the popover this is
/// offered from before the request answers.
Future<void> reportMember(
  BuildContext context,
  ProviderContainer container,
  api.UserProfile profile,
) => fileReport(
  context,
  container,
  subject: api.ReportSubject.user,
  subjectId: profile.id,
  subjectLabel: 'this member',
);

/// Opens a direct message with [profile] from the member card.
///
/// The card closes on tap, before the server answers, so a refusal (the other
/// person blocked you, or the request failed) is said on [host], which
/// outlives it.
Future<void> messageMember(
  BuildContext host,
  ProviderContainer container,
  api.UserProfile profile,
) async {
  final failure = await runGuarded(
    whatFailed: 'open a conversation with ${profile.displayName}',
    action: () async {
      final channelId = await openDirectMessage(container, profile.id);
      if (host.mounted) host.go(Routes.channel(channelId));
    },
  );
  if (failure != null && host.mounted) showAppSnackbar(host, failure);
}

/// Blocks a member from the row's context menu.
Future<void> blockMember(
  BuildContext context,
  ProviderContainer container,
  api.UserProfile profile,
) => blockUser(context, container, profile.id);

/// Unblocks a member from the row's context menu.
Future<void> unblockMember(
  BuildContext context,
  ProviderContainer container,
  api.UserProfile profile,
) => unblockUser(context, container, profile.id);

/// Toggles [profile] on or off the caller's own off-hours notification
/// schedule allow-list (`docs/decisions/0033-notification-schedule.md`) -
/// the member card's "notify me about this person off-hours" shortcut.
/// [currentlyAllowed] is read from the card at tap time rather than
/// re-fetched here, the same "decide from what the popover already knew"
/// shape [blockMember]/[unblockMember] split into two callers for; this one
/// stays a single toggle since there is only ever one menu row for it.
Future<void> toggleNotificationScheduleAllowedUser(
  BuildContext context,
  ProviderContainer container,
  api.UserProfile profile,
  bool currentlyAllowed,
) async {
  final client = container.read(apiProvider);
  final failure = await runGuarded(
    whatFailed: currentlyAllowed
        ? 'stop notifying you about this person off hours'
        : 'notify you about this person off hours',
    action: () => currentlyAllowed
        ? client.removeNotificationScheduleAllowedUser(profile.id)
        : client.addNotificationScheduleAllowedUser(profile.id),
  );
  if (failure == null) container.invalidate(notificationScheduleProvider);
  if (!context.mounted) return;
  showAppSnackbar(
    context,
    failure ??
        (currentlyAllowed
            ? 'Off hours now follow your usual schedule for this person.'
            : 'You will always be notified about this person, even off hours.'),
  );
}

/// Removes a member from the Space, from the row's context menu.
///
/// [container] must be captured before the popover is dismissed: this awaits
/// a confirmation dialog first, and by the time it answers a `ref` would be
/// tied to a disposed element - exactly the bug `member_profile.dart` exists
/// to avoid.
Future<void> removeMemberFromSpace(
  BuildContext host,
  ProviderContainer container,
  api.UserProfile profile,
) async {
  final name = profile.displayName;
  final confirmed = await confirmDangerousAction(
    host,
    title: 'Remove $name from this Space?',
    // Says what it does and does not do; "remove" misleads in both directions.
    message:
        'They will be signed out and cannot sign in again, and any '
        'invites they handed out stop working. Everything they wrote stays, '
        'still shown as theirs. You can let them back in later. '
        'This does not stop them making a new account and rejoining, '
        'especially if this Space is open to anyone with a link.',
    confirmLabel: 'Remove',
  );
  if (!confirmed) return;
  container.read(memberModerationErrorProvider.notifier).state = null;
  await runGuarded(
    whatFailed: 'remove $name',
    action: () => container.read(apiProvider).removeMember(userId: profile.id),
  ).then((failure) {
    if (failure == null) {
      container.invalidate(membersProvider);
    } else {
      container.read(memberModerationErrorProvider.notifier).state = failure;
    }
  });
}
