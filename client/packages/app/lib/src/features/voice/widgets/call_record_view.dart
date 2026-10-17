// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The row a finished DM call leaves in the transcript.
///
/// The server stores the outcome and nothing else - a call message's own
/// content is empty on purpose, because the same row reads differently from
/// each side. "Missed call" and "No answer" are one stored fact seen from two
/// ends, and freezing either wording into the database would make one of the
/// two people read a lie.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

/// What a call record says to whoever is reading it.
///
/// [viewerIsCaller] is the whole reason this is a function rather than a map:
/// every outcome but [api.CallOutcome.answered] is a call that did not happen,
/// and which side you were on decides whether that reads as something you
/// missed or something that went unanswered.
String callRecordLabel({
  required api.CallOutcome? outcome,
  required bool viewerIsCaller,
  int? durationMs,
}) => switch (outcome) {
  api.CallOutcome.answered =>
    durationMs == null ? 'Call' : 'Call · ${formatCallDuration(durationMs)}',
  api.CallOutcome.timedOut => viewerIsCaller ? 'No answer' : 'Missed call',
  api.CallOutcome.canceled => viewerIsCaller ? 'Call cancelled' : 'Missed call',
  api.CallOutcome.declined =>
    viewerIsCaller ? 'Call declined' : 'You declined this call',
  // An unknown outcome still happened; never leave the body empty.
  null => 'Call',
};

/// `4m 12s`, or `12s` under a minute. Never `0m 12s`, which reads as a bug.
String formatCallDuration(int durationMs) {
  final seconds = durationMs ~/ 1000;
  final minutes = seconds ~/ 60;
  return minutes == 0 ? '${seconds}s' : '${minutes}m ${seconds % 60}s';
}

/// A call, rendered in place of the empty body its message stores.
class CallRecordView extends StatelessWidget {
  const CallRecordView({
    super.key,
    required this.record,
    required this.viewerIsCaller,
  });

  final api.CallRecord record;
  final bool viewerIsCaller;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final missed = record.outcome?.wasMissed ?? false;
    final label = callRecordLabel(
      outcome: record.outcome,
      viewerIsCaller: viewerIsCaller,
      durationMs: record.durationMs,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          missed ? AppIcons.missedCall : AppIcons.startCall,
          size: AppSizes.icon16,
          // Colour is what makes a missed call findable while scrolling.
          color: missed ? tokens.dangerText : tokens.textSecondary,
        ),
        const SizedBox(width: AppSpacing.s8),
        Text(label, style: AppText.body.copyWith(color: tokens.textSecondary)),
      ],
    );
  }
}
