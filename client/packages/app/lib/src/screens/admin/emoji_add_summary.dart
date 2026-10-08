// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What an emoji add run reports once it has finished, or partly finished.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'emoji_bulk_plan.dart';
import 'emoji_name.dart';

/// One planned image and how its upload ended.
class EmojiAddResult {
  const EmojiAddResult({required this.upload, this.reason});

  final PlannedEmojiUpload upload;

  /// Null when the image was created.
  final String? reason;

  bool get failed => reason != null;
}

/// Failures and skips are grouped by reason rather than listed per file: a
/// refusal shared by a whole `POST /emoji/bulk` chunk would otherwise repeat
/// once per image. A cause only one file hit still names that file.
class EmojiAddSummary extends StatelessWidget {
  const EmojiAddSummary({
    super.key,
    required this.succeeded,
    required this.failed,
    required this.skipped,
  });

  final List<EmojiAddResult> succeeded;
  final List<EmojiAddResult> failed;
  final List<SkippedZipEntry> skipped;

  @override
  Widget build(BuildContext context) {
    final total = succeeded.length + failed.length + skipped.length;
    final groups = <String, List<String>>{};
    for (final r in failed) {
      (groups[r.reason ?? 'failed'] ??= []).add(r.upload.fileName);
    }
    for (final s in skipped) {
      (groups[s.reason] ??= []).add(s.fileName);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (succeeded.isNotEmpty || failed.isNotEmpty)
          AppCallout(
            tone: succeeded.length == total
                ? AppCalloutTone.accent
                : AppCalloutTone.warn,
            child: Text(
              'Added ${succeeded.length} of $total '
              'image${total == 1 ? '' : 's'}.',
            ),
          ),
        for (final entry in groups.entries)
          EmojiSkippedLine(fileNames: entry.value, reason: entry.key),
      ],
    );
  }
}

/// One grouped refusal line: a single file names itself, several sharing a
/// reason collapse into a count.
class EmojiSkippedLine extends StatelessWidget {
  const EmojiSkippedLine({
    super.key,
    required this.fileNames,
    required this.reason,
  });

  final List<String> fileNames;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final label = fileNames.length == 1
        ? '${fileNames.single}: $reason'
        : '${fileNames.length} images could not be added: $reason';
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s8),
      child: Text(
        label,
        style: AppText.caption.copyWith(color: tokens.dangerText),
      ),
    );
  }
}

/// Said after an upload whose image is already in the list under another
/// name. The emoji was added; this offers to take it back.
class EmojiSameImageNotice extends StatelessWidget {
  const EmojiSameImageNotice({
    super.key,
    required this.added,
    required this.existingName,
    required this.busy,
    required this.onUseExisting,
    required this.onKeep,
  });

  final api.CustomEmoji added;
  final String existingName;
  final bool busy;
  final VoidCallback onUseExisting;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final existing = emojiShortcode(existingName);
    return AppCallout(
      tone: AppCalloutTone.info,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${added.shortcode} was added, but it is the same image as '
            '$existing.',
          ),
          const SizedBox(height: AppSpacing.s8),
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: [
              AppButton(
                label: 'Use $existing instead',
                disabled: busy,
                onPressed: onUseExisting,
              ),
              AppButton(
                label: 'Keep both',
                variant: AppButtonVariant.ghost,
                disabled: busy,
                onPressed: onKeep,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
