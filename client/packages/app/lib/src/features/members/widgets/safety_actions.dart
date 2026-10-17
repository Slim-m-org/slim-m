// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reporting and blocking, from wherever they are offered.
///
/// One implementation for both subjects. Report and block existed twice before
/// this, once for a member row and once for a message's author, with the same
/// success wording written out in both files and the same catch around a
/// different verb. Two copies of a safety action is two places for the copy to
/// stop matching what actually happens, and the block half had already drifted:
/// it promised messages were hidden while nothing filtered any.
///
/// Every function here takes a [ProviderContainer], not a [WidgetRef]: the
/// caller dismisses the surface these are offered from before the request
/// answers (a popover pops, then a dialog is awaited), and a `WidgetRef` tied
/// to that surface's element throws once it is disposed. A container has no
/// such lifetime, so it is what a caller must capture before dismissing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../ids.dart';
import '../providers/blocks_controller.dart';
import '../providers/filed_reports.dart';
import '../../../providers/providers.dart';
import '../../../widgets/app_snackbar.dart';
import 'report_dialog.dart';
import '../../../widgets/run_guarded.dart';

/// Runs [action]; on success shows [succeeded], on failure the sentence
/// [runGuarded] turns the exception into for [whatFailed].
Future<void> _tell(
  BuildContext context,
  String whatFailed,
  String succeeded,
  Future<void> Function() action,
) async {
  final failure = await runGuarded(whatFailed: whatFailed, action: action);
  if (!context.mounted) return;
  showAppSnackbar(context, failure ?? succeeded);
}

/// Files a report about [subjectId], once the reporter has given a reason.
///
/// [subjectLabel] names the thing in the prompt ("this member", "this message"),
/// and is the only difference between the two callers. A private bot message
/// also passes the [channelId], [authorId] and [snapshot] the server cannot look up.
///
/// Remembers the new report's id in [filedReportsProvider] on success, so it
/// shows up in `ReportStatusSection` without the reporter ever seeing, let
/// alone writing down, a bare id themselves.
Future<void> fileReport(
  BuildContext context,
  ProviderContainer container, {
  required api.ReportSubject subject,
  required String subjectId,
  required String subjectLabel,
  String? channelId,
  String? authorId,
  String? snapshot,
}) async {
  final reason = await promptReportReason(context, subjectLabel: subjectLabel);
  if (reason == null || !context.mounted) return;
  final id = newReportId();
  await _tell(
    context,
    'file the report',
    'Report filed. A moderator will review it.',
    () async {
      final reportId = await container
          .read(apiProvider)
          .report(
            subject: subject,
            subjectId: subjectId,
            reason: reason,
            id: id,
            channelId: channelId,
            authorId: authorId,
            snapshot: snapshot,
          );
      await container.read(filedReportsProvider.notifier).record(reportId);
    },
  );
}

/// Blocks [userId]; see `SlimmApi.blockUser` for why they are never told.
///
/// Goes through [blocksProvider] rather than the API directly, so the id lands
/// in the set every read surface filters against and the transcript reacts to
/// the tap. The wording says only what is really covered: messages, reactions
/// and typing go, and the person stays in the member list where the block can
/// be undone.
Future<void> blockUser(
  BuildContext context,
  ProviderContainer container,
  String userId,
) => _tell(
  context,
  'block that user',
  'Blocked. You will not see what they post.',
  () => container.read(blocksProvider.notifier).block(userId),
);

/// Unblocks [userId], reporting a failure rather than swallowing it.
Future<void> unblockUser(
  BuildContext context,
  ProviderContainer container,
  String userId,
) => _tell(
  context,
  'unblock that user',
  'Unblocked.',
  () => container.read(blocksProvider.notifier).unblock(userId),
);
