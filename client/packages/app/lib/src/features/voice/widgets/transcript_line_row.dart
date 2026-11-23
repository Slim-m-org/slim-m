// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One transcript line: who said it, when, and what (decision 0113), in the
/// idle pane's Transcript section and the live pane alike.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../format.dart';
import '../../members/providers/user_profiles.dart';
import '../../members/widgets/user_avatar.dart';
import '../../settings/providers/display_preferences.dart';

Key transcriptLineKey(int seq) => ValueKey('transcript-line-$seq');

class TranscriptLineRow extends ConsumerWidget {
  const TranscriptLineRow({
    super.key,
    required this.line,
    required this.highlighted,
  });

  final api.TranscriptLine line;
  final bool highlighted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final name =
        ref
            .watch(userProfileProvider(line.speakerId))
            .valueOrNull
            ?.displayName ??
        'Someone';
    final time = formatClock(
      DateTime.fromMillisecondsSinceEpoch(line.at),
      use24Hour: watchUse24Hour(ref, context),
    );
    return Container(
      key: transcriptLineKey(line.seq),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
      decoration: BoxDecoration(
        color: highlighted ? tokens.accentSoft : null,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserAvatar(
            name: name,
            userId: line.speakerId,
            size: AppAvatarSize.s28,
          ),
          const SizedBox(width: AppSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui.copyWith(
                          color: tokens.textPrimary,
                          fontWeight: AppWeights.medium,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s8),
                    Text(
                      time,
                      style: AppText.code.copyWith(color: tokens.textSecondary),
                    ),
                  ],
                ),
                Text(
                  line.text,
                  style: AppText.body.copyWith(color: tokens.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
