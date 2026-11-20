// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Above a conversation while a jump to one of its messages is under way:
/// a quiet line while the message is paged in, and why it could not be
/// reached if it was not, so a tap from search or pins always has an answer.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/message_jump.dart';

class MessageJumpStatus extends ConsumerWidget {
  const MessageJumpStatus({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seeking = ref.watch(
      messageJumpProvider.select((s) => jumpSeekingIn(s, channelId)),
    );
    final notice = ref.watch(
      messageJumpProvider.select((s) => jumpNoticeFor(s, channelId)),
    );
    final jump = ref.read(messageJumpProvider.notifier);
    // Revealed rather than inserted, so a message that is found at once never flashes the line.
    return AppRevealBand(
      child: switch ((seeking, notice)) {
        (true, _) => const _SeekingLine(),
        (_, final notice?) => Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            AppSpacing.s8,
            AppSpacing.s16,
            0,
          ),
          child: AppErrorState(
            message: notice.text,
            onRetry: notice.retryable
                ? () => unawaited(jump.jumpTo(channelId, notice.messageId))
                : null,
            onDismiss: () => jump.dismissNotice(notice.token),
          ),
        ),
        _ => null,
      },
    );
  }
}

class _SeekingLine extends StatelessWidget {
  const _SeekingLine();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: AppSpacing.s8,
      ),
      child: Row(
        children: [
          const AppSpinner(size: AppSpinnerSize.sm),
          const SizedBox(width: AppSpacing.s8),
          Text(
            'Finding that message',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      ),
    );
  }
}
