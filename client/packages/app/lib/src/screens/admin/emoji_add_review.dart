// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The review step of adding emoji: every planned image beside an editable
/// name, with whatever would stop it uploading said on its own row.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/image_decode.dart';
import '../../widgets/standard_emoji.dart';
import 'emoji_bulk_plan.dart';
import 'emoji_name.dart';

/// One planned image whose name the admin may still change.
class EmojiReviewItem {
  EmojiReviewItem(this.upload)
    : name = TextEditingController(text: upload.name);

  final PlannedEmojiUpload upload;
  final TextEditingController name;

  /// The name the server would store for what is typed now.
  String get normalized => normalizeEmojiName(name.text);

  PlannedEmojiUpload get edited => PlannedEmojiUpload(
    fileName: upload.fileName,
    name: normalized,
    bytes: upload.bytes,
  );

  void dispose() => name.dispose();
}

/// What is wrong with each item's name, null where it is fine. The first of
/// two items sharing a name keeps it, as a zip with a repeated stem always has.
List<String?> reviewProblems(
  List<EmojiReviewItem> items,
  Set<String> existingNames,
) {
  final seen = <String>{};
  return [
    for (final item in items)
      () {
        final name = item.normalized;
        if (!isUsableEmojiName(name)) {
          return 'Letters, numbers and underscores, $maxEmojiNameLength at most.';
        }
        if (existingNames.contains(name)) return 'Already taken.';
        if (isStandardEmojiName(name)) return 'That is a standard emoji.';
        if (!seen.add(name)) return 'Another image has this name.';
        return null;
      }(),
  ];
}

class EmojiReviewList extends StatelessWidget {
  const EmojiReviewList({
    super.key,
    required this.items,
    required this.problems,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
  });

  final List<EmojiReviewItem> items;
  final List<String?> problems;
  final bool enabled;
  final VoidCallback onChanged;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: items.length,
        itemBuilder: (context, i) => _ReviewRow(
          key: ObjectKey(items[i]),
          item: items[i],
          problem: problems[i],
          enabled: enabled,
          onChanged: onChanged,
          onRemove: () => onRemove(i),
        ),
      ),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    super.key,
    required this.item,
    required this.problem,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
  });

  final EmojiReviewItem item;
  final String? problem;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Thumb(bytes: item.upload.bytes),
              const SizedBox(width: AppSpacing.s12),
              Expanded(
                child: AppInput(
                  controller: item.name,
                  enabled: enabled,
                  mono: true,
                  semanticLabel: 'Name for ${item.upload.fileName}',
                  onChanged: (_) => onChanged(),
                ),
              ),
              AppIconButton(
                icon: AppIcons.dismiss,
                semanticLabel: 'Remove ${item.upload.fileName}',
                onPressed: enabled ? onRemove : null,
              ),
            ],
          ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(
                top: AppSpacing.s4,
                left: AppSizes.icon24 + AppSpacing.s12,
              ),
              child: Text(
                problem!,
                style: AppText.caption.copyWith(color: tokens.dangerText),
              ),
            ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.bytes});

  final List<int> bytes;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    const size = AppSizes.icon24;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Image.memory(
        Uint8List.fromList(bytes),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        cacheWidth: decodeEdge(context, size),
        cacheHeight: decodeEdge(context, size),
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}
