// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The moderation quick actions a report card offers: delete the reported
/// message, time out its author, or remove them from the Space.
///
/// Split out of `report_card.dart` to keep that file under budget. Each
/// takes the caller's own [Guard] (`run_guarded.dart`) rather than holding
/// its own state, so a failure renders through the card's existing
/// `AppErrorState` instead of a second error surface. Every one of these
/// closes the report as resolved once it succeeds: taking a quick action is
/// what handling a report means here, so it should not also sit in the queue
/// waiting for a separate tap.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../../providers/providers.dart';
import '../../../members/providers/reports_controller.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../../widgets/run_guarded.dart';

/// Whether [channelId] is one this moderator's client already knows about -
/// which, since the local channel list is exactly what `GET /channels`
/// granted, is a reliable stand-in for "can view it". A deleted message
/// cannot be told apart from one merely not paged in yet without a jump
/// actually being attempted, so that case is left to the jump itself, which
/// fails visibly (`message_jump.dart`) rather than silently; any failure
/// reading the store reads as unreachable too, the safe default for "should
/// this offer a jump that might fail".
Future<bool> reportedChannelReachable(WidgetRef ref, String channelId) async {
  try {
    final store = await ref.read(storeProvider.future);
    return await store.hasChannel(channelId);
  } catch (error, stack) {
    api.AppLog.swallowed(
      api.LogTag.ui,
      'Could not check whether the reported channel is available locally',
      error,
      stack,
    );
    return false;
  }
}

Future<void> _closeReport(
  ProviderContainer container,
  Guard guard,
  String reportId,
) => guard(
  whatFailed: 'close the report',
  action: () async {
    await container
        .read(apiProvider)
        .resolveReport(
          reportId: reportId,
          resolution: api.ReportResolution.resolved,
        );
    if (container.exists(reportsControllerProvider)) {
      await container.read(reportsControllerProvider.notifier).refresh();
    }
  },
);

/// Runs [action], then closes the report, which still happens if the card has left the screen.
Future<void> _actThenClose(
  ProviderContainer container,
  Guard guard,
  String reportId, {
  required String whatFailed,
  required Future<void> Function() action,
}) async {
  final acted = await guard(whatFailed: whatFailed, action: action);
  if (acted) await _closeReport(container, guard, reportId);
}

/// Deletes the reported message, after confirming - a delete removes it for
/// everyone in the channel and cannot be undone.
Future<void> deleteReportedMessage(
  BuildContext context,
  ProviderContainer container,
  Guard guard, {
  required String channelId,
  required String messageId,
  required String reportId,
}) async {
  final confirmed = await confirmDangerousAction(
    context,
    title: deleteMessageConfirmTitle,
    message: deleteMessageConfirmMessage,
    confirmLabel: 'Delete',
  );
  if (!confirmed || !context.mounted) return;
  await _actThenClose(
    container,
    guard,
    reportId,
    whatFailed: 'delete the message',
    action: () async {
      await container
          .read(apiProvider)
          .deleteMessage(channelId: channelId, messageId: messageId);
      final store = await container.read(storeProvider.future);
      await store.discard(messageId);
    },
  );
}

/// Times the reported author out. No confirmation, matching
/// `TimeoutDurationChips`'s own reasoning: it lapses on its own and the undo
/// sits on the resulting badge, so a dialog here would only be a speed bump.
Future<void> timeOutReportedAuthor(
  ProviderContainer container,
  Guard guard, {
  required String userId,
  required Duration duration,
  required String reportId,
}) => _actThenClose(
  container,
  guard,
  reportId,
  whatFailed: 'time this member out',
  action: () => container
      .read(apiProvider)
      .timeOutMember(userId: userId, duration: duration),
);

/// Removes the reported author from the Space, after confirming - this is a
/// ban in behaviour: they are signed out and cannot sign back in.
Future<void> removeReportedAuthor(
  BuildContext context,
  ProviderContainer container,
  Guard guard, {
  required String userId,
  required String name,
  required String reportId,
}) async {
  final confirmed = await confirmDangerousAction(
    context,
    title: 'Remove $name from this Space?',
    // "cannot sign in again" is about this account, not this person.
    message:
        'They will be signed out and cannot sign in again, and any '
        'invites they handed out stop working. Everything they wrote stays, '
        'still shown as theirs. You can let them back in later. '
        'This does not stop them making a new account and rejoining, '
        'especially if this Space is open to anyone with a link.',
    confirmLabel: 'Remove',
  );
  if (!confirmed || !context.mounted) return;
  await _actThenClose(
    container,
    guard,
    reportId,
    whatFailed: 'remove $name',
    action: () => container.read(apiProvider).removeMember(userId: userId),
  );
}
