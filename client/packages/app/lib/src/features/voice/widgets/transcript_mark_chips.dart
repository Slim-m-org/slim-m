// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The marks and notes that point at one transcript line, under it: who made
/// each, and the note when there is one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/user_profiles.dart';

Key transcriptMarkChipKey(String markId) => ValueKey('transcript-mark-$markId');

/// What a mark says about itself: "Alex marked this", or "Alex: the note".
String transcriptMarkLabel(api.TranscriptMark mark, String name) =>
    mark.text == null ? '$name marked this' : '$name: ${mark.text}';

class TranscriptMarkChips extends StatelessWidget {
  const TranscriptMarkChips({super.key, required this.marks});

  final List<api.TranscriptMark> marks;

  @override
  Widget build(BuildContext context) {
    if (marks.isEmpty) return const SizedBox.shrink();
    return Padding(
      // Lines up with the line's text, past its avatar and gap.
      padding: const EdgeInsets.only(
        left: AppAvatarSize.s28 + AppSpacing.s12,
        bottom: AppSpacing.s4,
      ),
      child: Wrap(
        spacing: AppSpacing.s8,
        runSpacing: AppSpacing.s4,
        children: [for (final mark in marks) _MarkChip(mark: mark)],
      ),
    );
  }
}

class _MarkChip extends ConsumerWidget {
  const _MarkChip({required this.mark});

  final api.TranscriptMark mark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final name =
        ref
            .watch(userProfileProvider(mark.authorId))
            .valueOrNull
            ?.displayName ??
        'Someone';
    return Container(
      key: transcriptMarkChipKey(mark.id),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: tokens.accentSoft,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            mark.text == null ? AppIcons.callMark : AppIcons.callNote,
            size: AppSizes.icon12,
            color: tokens.textSecondary,
          ),
          const SizedBox(width: AppSpacing.s4),
          Flexible(
            child: Text(
              transcriptMarkLabel(mark, name),
              style: AppText.caption.copyWith(color: tokens.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
