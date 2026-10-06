// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two verbs behind the member pane's selection bar.
///
/// Separate from the pane for the reason `channel_message_actions.dart` is
/// separate from the transcript: confirming, reporting and clearing are three
/// steps that read as an aside inside a widget's `build`, and the pane is a
/// layout file.
///
/// The selection is cleared only on success. A refused batch leaves it intact
/// to retry or cancel, since rebuilding a thirty-member selection by hand is
/// the expensive part - the same rule the message selection keeps.
///
/// Both verbs are all-or-nothing server-side: a batch naming somebody above
/// the caller's own permissions removes nobody. So there is no partial state
/// to explain here, and a failure sentence can speak about the whole batch.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../providers/member_moderation_error.dart';
import '../providers/member_selection.dart';
import '../providers/providers.dart';
import 'confirm_dialog.dart';
import 'run_guarded.dart';

/// Confirms, then removes every selected member.
///
/// Confirmed because it is the destructive half: a removal revokes sessions
/// and invites and does not lapse on its own, unlike the timeout beside it.
Future<void> confirmAndRemoveSelectedMembers(
  WidgetRef ref,
  BuildContext context,
) async {
  final ids = ref.read(memberSelectionProvider).ids.toList();
  if (ids.isEmpty) return;
  final confirmed = await confirmDangerousAction(
    context,
    title: ids.length == 1 ? 'Remove member?' : 'Remove ${ids.length} members?',
    message:
        'They lose access and their invites are revoked. Everything they '
        'wrote stays, still attributed to them.',
    confirmLabel: 'Remove',
  );
  if (!confirmed || !context.mounted) return;

  ref.read(memberModerationErrorProvider.notifier).state = null;
  final failure = await runGuarded(
    whatFailed: ids.length == 1 ? 'remove the member' : 'remove the members',
    action: () => ref.read(apiProvider).bulkRemoveMembers(userIds: ids),
  );
  if (failure != null) {
    ref.read(memberModerationErrorProvider.notifier).state = failure;
    return;
  }
  ref.read(memberSelectionProvider.notifier).clear();
}

/// Times every selected member out for [duration].
///
/// No confirmation, matching the single member's own timeout chips: a timeout
/// lapses on its own and re-issuing replaces it, so the act is reversible by
/// doing it again.
Future<void> timeOutSelectedMembers(WidgetRef ref, Duration duration) async {
  final ids = ref.read(memberSelectionProvider).ids.toList();
  if (ids.isEmpty) return;

  ref.read(memberModerationErrorProvider.notifier).state = null;
  final failure = await runGuarded(
    whatFailed: ids.length == 1
        ? 'time the member out'
        : 'time the members out',
    action: () => ref
        .read(apiProvider)
        .bulkTimeoutMembers(userIds: ids, duration: duration),
  );
  if (failure != null) {
    ref.read(memberModerationErrorProvider.notifier).state = failure;
    return;
  }
  ref.read(memberSelectionProvider.notifier).clear();
}
