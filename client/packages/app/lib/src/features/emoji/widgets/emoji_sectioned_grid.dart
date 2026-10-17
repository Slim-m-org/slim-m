// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's browse view: every [EmojiSection] as one continuous
/// scrollable, a real `SliverGrid` per section so a category nobody has
/// scrolled to yet never builds its cells - unlike `EmojiGrid`'s own
/// `shrinkWrap: true` mode, right for `_SpaceEmojiSheet`'s small deployment
/// list but wrong for the whole native catalog sitting behind one scroll.
///
/// [EmojiCategoryRail] jumps here rather than tracking scroll position live:
/// [emojiSectionScrollOffset] estimates where a section starts from its
/// item counts alone, so the jump works even for a section nothing has
/// built yet - deliberately a first cut, not scroll-linked selection; see
/// `composer_emoji_browse.dart` for the call site and why.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'emoji_catalog.dart';
import 'emoji_picker_grid.dart';

class EmojiSectionedGrid extends StatelessWidget {
  const EmojiSectionedGrid({
    super.key,
    required this.controller,
    required this.sections,
    required this.highlighted,
    required this.onTap,
    this.onHoverChange,
    this.onPressChange,
  });

  final ScrollController controller;
  final List<EmojiSection> sections;

  /// An index into the sections flattened end to end, matching how a caller
  /// tracking keyboard `ArrowUp`/`ArrowDown` across the whole browse view
  /// already flattens them for that purpose.
  final int highlighted;
  final ValueChanged<PickerEmoji> onTap;
  final void Function(PickerEmoji emoji, bool active)? onHoverChange;
  final void Function(PickerEmoji emoji, bool active)? onPressChange;

  /// A header's fixed height, so [emojiSectionScrollOffset] can add it up
  /// exactly rather than guessing at a `Text`'s measured one.
  static const double headerHeight = 28;
  static const double sectionGap = AppSpacing.s4;
  static const double gridInset = AppSpacing.s8;

  @override
  Widget build(BuildContext context) {
    var flatIndex = 0;
    final slivers = <Widget>[];
    for (final section in sections) {
      slivers.add(
        SliverToBoxAdapter(
          child: SizedBox(
            height: headerHeight,
            child: AppMenuLabel(section.category.sectionLabel),
          ),
        ),
      );
      final sectionStart = flatIndex;
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: gridInset),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: EmojiGrid.cellExtent,
              mainAxisSpacing: AppSpacing.s4,
              crossAxisSpacing: AppSpacing.s4,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => _cell(section.emoji[i], sectionStart + i),
              childCount: section.emoji.length,
            ),
          ),
        ),
      );
      flatIndex += section.emoji.length;
      slivers.add(
        const SliverToBoxAdapter(child: SizedBox(height: sectionGap)),
      );
    }
    return CustomScrollView(controller: controller, slivers: slivers);
  }

  Widget _cell(PickerEmoji emoji, int index) => EmojiCell(
    emoji: emoji,
    highlighted: index == highlighted,
    onTap: () => onTap(emoji),
    onHoverChange: onHoverChange == null
        ? null
        : (active) => onHoverChange!(emoji, active),
    onPressChange: onPressChange == null
        ? null
        : (active) => onPressChange!(emoji, active),
  );
}

/// Where [category]'s header would sit if every row above it in [sections]
/// laid out at exactly [EmojiGrid.cellExtent] - an estimate, not a
/// measurement: real rows can land a few pixels off this once built, which
/// is fine for a jump a member then keeps scrolling from, not a precise
/// scroll-to-exact-pixel contract.
double emojiSectionScrollOffset({
  required EmojiCategory category,
  required List<EmojiSection> sections,
  required double crossAxisExtent,
}) {
  const spacing = AppSpacing.s4;
  final columns = math.max(
    1,
    (crossAxisExtent / (EmojiGrid.cellExtent + spacing)).ceil(),
  );
  var offset = 0.0;
  for (final section in sections) {
    if (section.category == category) return offset;
    final rows = (section.emoji.length / columns).ceil();
    offset +=
        EmojiSectionedGrid.headerHeight +
        rows * (EmojiGrid.cellExtent + spacing) +
        EmojiSectionedGrid.sectionGap;
  }
  return offset;
}
