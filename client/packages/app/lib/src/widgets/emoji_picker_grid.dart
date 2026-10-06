// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The emoji picker's category tab row and result grid.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'custom_emoji_image.dart';
import 'emoji_catalog.dart';
import 'emoji_grid_navigator.dart';

/// The row of category tabs above the grid. Hidden by the panel while a
/// search is active, since a query already narrows the whole catalog.
class EmojiCategoryTabs extends StatelessWidget {
  const EmojiCategoryTabs({
    super.key,
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final List<EmojiCategory> categories;
  final EmojiCategory selected;
  final ValueChanged<EmojiCategory> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final category in categories)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
              child: AppIconButton(
                icon: category.icon,
                semanticLabel: category.label,
                tooltip: category.label,
                size: AppIconButtonSize.sm,
                iconSize: AppSizes.icon16,
                active: category == selected,
                onPressed: () => onSelect(category),
              ),
            ),
        ],
      ),
    );
  }
}

/// The vertical rail beside the browse view's continuous scroll: one icon
/// per section, jumping the scroll position there rather than filtering the
/// grid the way [EmojiCategoryTabs] does. See `emoji_sectioned_grid.dart`
/// for the jump itself and why it does not track live scroll position.
class EmojiCategoryRail extends StatelessWidget {
  const EmojiCategoryRail({
    super.key,
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final List<EmojiCategory> categories;

  /// Null before any jump has been made; see `emoji_sectioned_grid.dart`.
  final EmojiCategory? selected;
  final ValueChanged<EmojiCategory> onSelect;

  /// The rail's own fixed width, so a caller sizing the grid beside it does
  /// not have to measure this.
  static const double width = 32;

  /// One entry's slot: its [AppSizes.rowPointer] hit box and the 1 px above
  /// and below it.
  static const double entryExtent = AppSizes.rowPointer + 2;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      // No scrollbar: at 32 wide its track lands on the icons, not beside them.
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          child: Column(
            children: [
              for (final category in categories)
                Padding(
                  // 1 is literal: no token sits between nothing and s4 here.
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: AppIconButton(
                    icon: category.icon,
                    semanticLabel: category.label,
                    tooltip: category.label,
                    size: AppIconButtonSize.sm,
                    iconSize: AppSizes.icon16,
                    active: category == selected,
                    // Selection is the only state worth painting in a column this narrow.
                    suppressOwnHoverFill: true,
                    onPressed: () => onSelect(category),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A grid of [emoji], with [highlighted] drawing the one keyboard
/// `ArrowUp`/`ArrowDown` navigation currently sits on. Own scroll view: the
/// panel gives it a bounded height and lets it page internally.
///
/// Sized by cell rather than by column count. A fixed count makes the cell as
/// wide as whatever surface it lands in, and the same grid serves a 320pt
/// anchored popup and a bottom sheet that is 414pt on a phone and 624pt on a
/// desktop; at eight columns that last one drew 71pt cells around a 20pt
/// glyph. Against [cellExtent] the column count varies instead and every cell
/// lands between roughly 38 and 44pt on all three.
class EmojiGrid extends StatefulWidget {
  const EmojiGrid({
    super.key,
    required this.emoji,
    required this.highlighted,
    required this.onTap,
    this.navigator,
    this.shrinkWrap = false,
    this.onHoverChange,
    this.onPressChange,
  });

  final List<PickerEmoji> emoji;
  final int highlighted;
  final ValueChanged<PickerEmoji> onTap;

  /// Lent by an owner that steers [highlighted] with the keyboard, so it can
  /// step by rows. Without one the grid keeps its own, which still scrolls a
  /// changed highlight into view.
  final EmojiGridNavigator? navigator;

  /// On for a caller that bounds the grid by a maximum rather than a fixed
  /// height, so a handful of tiles occupies a handful of rows.
  final bool shrinkWrap;

  /// Null everywhere this grid does not feed a preview footer - only the
  /// composer's browse view (`composer_emoji_browse.dart`) does, for its
  /// search results.
  final void Function(PickerEmoji emoji, bool active)? onHoverChange;
  final void Function(PickerEmoji emoji, bool active)? onPressChange;

  /// A cell's target size, and the ceiling on its measured one. It is
  /// [AppSizes.rowTouch] because a cell is a tap target: the sheet is the
  /// touch surface, and nothing here should ask for a smaller one.
  static const double cellExtent = AppSizes.rowTouch;

  @override
  State<EmojiGrid> createState() => _EmojiGridState();
}

class _EmojiGridState extends State<EmojiGrid> {
  EmojiGridNavigator? _own;

  EmojiGridNavigator get _navigator =>
      widget.navigator ?? (_own ??= EmojiGridNavigator());

  @override
  void didUpdateWidget(covariant EmojiGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.highlighted == oldWidget.highlighted) return;
    // After layout: the cell a new highlight points at may not be built yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _navigator.reveal(widget.highlighted);
    });
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _navigator.layout(constraints.maxWidth, EmojiGrid.cellExtent);
        return GridView.builder(
          controller: _navigator.scroll,
          shrinkWrap: widget.shrinkWrap,
          padding: const EdgeInsets.all(EmojiGridNavigator.padding),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: EmojiGrid.cellExtent,
            mainAxisSpacing: EmojiGridNavigator.gap,
            crossAxisSpacing: EmojiGridNavigator.gap,
          ),
          itemCount: widget.emoji.length,
          itemBuilder: (context, index) {
            final tile = widget.emoji[index];
            return EmojiCell(
              emoji: tile,
              highlighted: index == widget.highlighted,
              onTap: () => widget.onTap(tile),
              onHoverChange: widget.onHoverChange == null
                  ? null
                  : (active) => widget.onHoverChange!(tile, active),
              onPressChange: widget.onPressChange == null
                  ? null
                  : (active) => widget.onPressChange!(tile, active),
            );
          },
        );
      },
    );
  }
}

/// One tile. Built directly on [FocusableActionDetector] rather than the
/// form package's `FocusableTapTarget`: that widget floors its hit target at
/// [AppSizes.rowPointer]/[AppSizes.rowTouch], which is larger than a dense
/// grid cell and would overflow it. [AppMenuItem] takes the same low-level
/// approach for the same reason.
///
/// Public (not `_`-prefixed) so `emoji_sectioned_grid.dart` can place these
/// directly in its own sliver grids rather than [EmojiGrid]'s bounded one.
class EmojiCell extends StatefulWidget {
  const EmojiCell({
    super.key,
    required this.emoji,
    required this.highlighted,
    required this.onTap,
    this.onHoverChange,
    this.onPressChange,
  });

  final PickerEmoji emoji;
  final bool highlighted;
  final VoidCallback onTap;

  /// Feeds the preview footer: hover is the pointer's own story, a held
  /// press ([onPressChange]) is touch's - see desktop-vs-mobile.md's rule 1
  /// on every hover affordance needing a named long-press-shaped equivalent.
  final ValueChanged<bool>? onHoverChange;
  final ValueChanged<bool>? onPressChange;

  @override
  State<EmojiCell> createState() => _EmojiCellState();
}

class _EmojiCellState extends State<EmojiCell> {
  bool _hovered = false;
  bool _focused = false;

  void _setPressed(bool pressed) {
    widget.onPressChange?.call(pressed);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final fill = widget.highlighted
        ? tokens.accentSoft
        : (_hovered ? tokens.surfaceSunken : Colors.transparent);

    final content = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        border: widget.highlighted
            ? Border.all(color: tokens.accentFill)
            : null,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      foregroundDecoration: _focused
          ? BoxDecoration(
              border: Border.all(color: tokens.focusRing, width: 2),
              borderRadius: BorderRadius.circular(AppRadii.control),
            )
          : null,

      /// 20, not on AppText's scale: sized to read as a legible glyph rather
      /// than any text style, the same literal exception AppChip.reaction
      /// documents for its own emoji glyph. An uploaded image is drawn to the
      /// same 20 so the two kinds sit on one visual line.
      child: switch (widget.emoji) {
        UnicodeEmoji(:final emoji) => Text(
          emoji.char,
          style: const TextStyle(fontSize: 20, height: 1),
        ),
        DeploymentEmoji(:final emoji) => CustomEmojiImage(emojiId: emoji.id),
      },
    );

    return Semantics(
      label: widget.emoji.label,
      button: true,
      selected: widget.highlighted,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) {
          setState(() => _hovered = v);
          widget.onHoverChange?.call(v);
        },
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => widget.onTap(),
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          child: content,
        ),
      ),
    );
  }
}
