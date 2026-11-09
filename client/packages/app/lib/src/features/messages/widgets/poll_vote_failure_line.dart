// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The persistent line under a poll when the viewer's vote was refused.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../composer/widgets/poll_view.dart' show pollCardMaxWidth;
import '../providers/message_actions.dart';
import '../providers/poll_vote_failure.dart';

class PollVoteFailureLine extends ConsumerWidget {
  const PollVoteFailureLine({super.key, required this.messageId});

  final String messageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failure = ref.watch(pollVoteFailureProvider(messageId));
    if (failure == null) return const SizedBox.shrink();
    final notifier = ref.read(pollVoteFailureProvider(messageId).notifier);
    final ballot = failure.ballot;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: pollCardMaxWidth),
        child: AppErrorState(
          message: failure.message,
          onRetry: () => unawaited(switch (ballot.ranking) {
            final ranking? => castRanking(ref, messageId, ranking),
            null => castVote(ref, messageId, ballot.option!),
          }),
          onDismiss: () => notifier.state = null,
        ),
      ),
    );
  }
}
