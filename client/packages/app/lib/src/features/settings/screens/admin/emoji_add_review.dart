// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The review step of adding emoji: every planned image beside an editable
/// name, with whatever would stop it uploading said on its own row.
///
/// The server's rules for a name are the source of truth: `normalize_name` and
/// `emoji::builtin` in `crates/slimm-server/src/emoji.rs`, plus the one-name-
/// per-Space rule its 409 enforces. [reviewProblems] mirrors them so none of
/// those refusals waits for an upload.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../widgets/image_decode.dart';
import '../../../emoji/widgets/standard_emoji.dart';
import 'emoji_bulk_plan.dart';
import 'emoji_name.dart';

const nameTakenProblem = 'Already taken.';
const _standardEmojiProblem = 'That is a standard emoji.';
const _unusableNameProblem = 'Use letters, numbers and underscores.';

/// The row problem for a reason the server gave for refusing one image, or
/// null for a reason that is not about its name.
String? problemForRefusal(String code) => switch (code) {
  'name_taken' => nameTakenProblem,
  'builtin_name' => _standardEmojiProblem,
  'unusable_name' => _unusableNameProblem,
  _ => null,
};

/// One planned image whose name the admin may still change.
class EmojiReviewItem {
  EmojiReviewItem(this.upload)
    : name = TextEditingController(text: upload.name);

  final PlannedEmojiUpload upload;
  final TextEditingController name;

  /// Identifies this item's row, so the list can be scrolled to it.
  final rowKey = GlobalKey();

  ({String name, String problem})? _refused;

  /// The name the server would store for what is typed now.
  String get normalized => normalizeEmojiName(name.text);

  /// Remembers the server refusing [refusedName] with [problem]; it holds until the name is changed.
  void refuse(String refusedName, String problem) =>
      _refused = (name: refusedName, problem: problem);

  String? get _refusal {
    final refused = _refused;
    return refused != null && refused.name == normalized
        ? refused.problem
        : null;
  }

  PlannedEmojiUpload get edited => PlannedEmojiUpload(
    fileName: upload.fileName,
    name: normalized,
    bytes: upload.bytes,
  );

  void dispose() => name.dispose();
}

/// What is wrong with each item's name, null where it is fine. The first of
/// two items sharing a name keeps it.
List<String?> reviewProblems(
  List<EmojiReviewItem> items,
  Set<String> existingNames,
) {
  final seen = <String>{};
  return [for (final item in items) _problemWith(item, existingNames, seen)];
}

String? _problemWith(
  EmojiReviewItem item,
  Set<String> existing,
  Set<String> seen,
) {
  final name = item.normalized;
  if (name.isEmpty) return _unusableNameProblem;
  if (name.length > maxEmojiNameLength) {
    return 'Too long, $maxEmojiNameLength characters at most.';
  }
  if (existing.contains(name)) return nameTakenProblem;
  if (isStandardEmojiName(name)) return _standardEmojiProblem;
  if (!seen.add(name)) return 'Another image has this name.';
  return item._refusal;
}

/// Scrolls the list [scroll] drives until the row of [items]`[index]` is on
/// screen, walking to it a frame at a time because the lazy list builds no row
/// it has not been near.
void revealReviewRow(
  ScrollController scroll,
  List<EmojiReviewItem> items,
  int index,
) => _approach(scroll, items, index, _maxApproachFrames);

/// Each step re-measures the rows built so far, so rows taller than assumed
/// (a problem line, a larger text scale) only cost another frame.
const _maxApproachFrames = 12;

void _approach(
  ScrollController scroll,
  List<EmojiReviewItem> items,
  int index,
  int framesLeft,
) {
  if (index >= items.length) return;
  final row = items[index].rowKey.currentContext;
  if (row != null) {
    unawaited(Scrollable.ensureVisible(row));
    return;
  }
  if (framesLeft == 0 || !scroll.hasClients) return;
  scroll.jumpTo(_offsetNear(scroll.position, items, index));
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => _approach(scroll, items, index, framesLeft - 1),
  );
}

/// Where the row at [index] should sit, extrapolated from the first row built.
double _offsetNear(
  ScrollPosition position,
  List<EmojiReviewItem> items,
  int index,
) {
  final built = [
    for (var i = 0; i < items.length; i++)
      if (items[i].rowKey.currentContext?.findRenderObject()
          case final RenderBox box when box.hasSize)
        (index: i, box: box),
  ];
  if (built.isEmpty) return index * _rowExtent;
  final first = built.first;
  final height =
      built.fold(0.0, (sum, row) => sum + row.box.size.height) / built.length;
  final firstOffset = RenderAbstractViewport.of(
    first.box,
  ).getOffsetToReveal(first.box, 0).offset;
  return (firstOffset + (index - first.index) * height).clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
}

class EmojiReviewList extends StatelessWidget {
  const EmojiReviewList({
    super.key,
    required this.items,
    required this.problems,
    required this.scroll,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
  });

  final List<EmojiReviewItem> items;
  final List<String?> problems;
  final ScrollController scroll;
  final bool enabled;
  final VoidCallback onChanged;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView.builder(
        key: const ValueKey('emoji-review-list'),
        controller: scroll,
        shrinkWrap: true,
        itemCount: items.length,
        itemBuilder: (context, i) => _ReviewRow(
          key: items[i].rowKey,
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
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.s12,
        children: [
          _besideTheField(_Thumb(bytes: item.upload.bytes)),
          Expanded(
            child: AppInput(
              key: ValueKey('emoji-name-${item.upload.fileName}'),
              controller: item.name,
              enabled: enabled,
              mono: true,
              placeholder: 'Emoji name',
              errorText: problem,
              semanticLabel: 'Name for ${item.upload.fileName}',
              onChanged: (_) => onChanged(),
            ),
          ),
          _besideTheField(
            AppIconButton(
              key: ValueKey('emoji-remove-${item.upload.fileName}'),
              icon: AppIcons.dismiss,
              semanticLabel: 'Remove ${item.upload.fileName}',
              onPressed: enabled ? onRemove : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Centres [child] on the field's own box, so a problem line under it does not drag the neighbours down.
Widget _besideTheField(Widget child) => SizedBox(
  height: _fieldBoxHeight,
  child: Center(child: child),
);

/// The field's height plus the focus ring it reserves around itself.
const double _fieldBoxHeight = AppSizes.controlLg + AppSpacing.s4;

/// What a row without a problem takes in the list, to start from before any is built.
const double _rowExtent = _fieldBoxHeight + AppSpacing.s8;

class _Thumb extends StatelessWidget {
  const _Thumb({required this.bytes});

  final List<int> bytes;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    const size = AppSizes.icon32;
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
