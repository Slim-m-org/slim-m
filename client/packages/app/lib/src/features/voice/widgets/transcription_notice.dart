// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-time notice before a member's first join while the Space transcribes
/// every call (decision 0113). The server remembers the acknowledgement per
/// member, so it shows once across devices and never on a later call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

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
  if (!await actions.isDue() || !context.mounted) return true;
  final joined = await showAppSheet<bool>(
    context,
    builder: (context) => const _NoticeSheet(),
  );
  if (joined != true) return false;
  await actions.acknowledge();
  return true;
}

class _NoticeSheet extends StatelessWidget {
  const _NoticeSheet();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Calls in this Space are transcribed',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          Text(
            'What is said is written down and kept with the call, '
            'for members who may read it.',
            style: AppText.body.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s16),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  key: transcriptionNoticeCancelKey,
                  label: 'Cancel',
                  variant: AppButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: AppButton(
                  key: transcriptionNoticeJoinKey,
                  label: 'Join',
                  variant: AppButtonVariant.primary,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
