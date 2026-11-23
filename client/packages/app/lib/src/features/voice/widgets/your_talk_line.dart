// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "You talked 6 min, 140 words a minute" for one call: the caller's own numbers, on their own client only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/call_stats.dart';
import 'call_stats_format.dart';

class YourTalkLine extends ConsumerWidget {
  const YourTalkLine({super.key, required this.transcriptId});

  final String transcriptId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref
        .watch(myCallStatsForCallProvider(transcriptId))
        .valueOrNull;
    if (stats == null || stats.isEmpty) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final pace = stats.wordsPerMinute;
    final text = StringBuffer('You talked ${formatTalkTime(stats.talkMs)}');
    if (pace != null) text.write(', ${formatPace(pace)} words a minute');
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s12),
      child: Text(
        text.toString(),
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}
