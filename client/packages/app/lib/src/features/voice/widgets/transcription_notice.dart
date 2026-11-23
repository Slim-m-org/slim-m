// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-time notice before a member's first join while the Space transcribes
/// every call (decision 0113). The server remembers the acknowledgement per
/// member, so it shows once across devices and never on a later call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/confirm_dialog.dart';
import '../providers/transcription_notice.dart';

const transcriptionNoticeJoinKey = Key('transcription-notice-join');
const transcriptionNoticeCancelKey = Key('transcription-notice-cancel');

/// Whether to go ahead and join: true when no notice is due, or the member
/// chose Join (which records the acknowledgement first).
Future<bool> confirmTranscriptionNotice(
  BuildContext context,
  WidgetRef ref,
) async {
  final actions = ref.read(transcriptionNoticeActionsProvider);
  final notice = await actions.dueNotice();
  if (notice == null || !context.mounted) return true;
  final joined = await confirmChoice(
    context,
    title: 'Calls in this Space are transcribed',
    message: [
      'What is said is written down and kept with the call, '
          'for members who may read it.',
      if (notice.voiceCommands)
        'Say "${notice.phrase}, mark that" to mark a moment.',
    ].join(' '),
    confirmLabel: 'Join',
    confirmKey: transcriptionNoticeJoinKey,
    cancelKey: transcriptionNoticeCancelKey,
  );
  if (!joined) return false;
  await actions.acknowledge();
  return true;
}
