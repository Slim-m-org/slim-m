// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's own Emoji tab content: search, a vertical category rail,
/// a continuous scrollable of sections, and a hover/press/keyboard-driven
/// preview footer - Discord's own shape. `EmojiPickerPanel` (the hover
/// reaction picker and its sheets) keeps its own horizontal tabs and single
/// grid unchanged; see the PR body for why this is scoped to the composer
/// rather than applied there too.
///
/// A search still swaps the whole view to one flat [EmojiGrid], exactly
/// [EmojiPickerPanel]'s own search behavior, since a query already narrows
/// the catalog to something small enough that sections buy nothing.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show CustomEmoji;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../providers/admin_providers.dart';
import '../providers/recent_emoji.dart';
import 'emoji_catalog.dart';
import 'emoji_grid_navigator.dart';
import 'emoji_picker_grid.dart';
import 'emoji_preview_footer.dart';
import 'emoji_section_navigation.dart';
import 'emoji_sectioned_grid.dart';

/// The rail-plus-grid area's own fixed height: tall enough that the rail shows
/// every default category, with Flags last, instead of clipping the end of it.
final double _browseHeight =
    emojiCategoriesInOrder.length * EmojiCategoryRail.entryExtent;

class ComposerEmojiPicker extends ConsumerStatefulWidget {
  const ComposerEmojiPicker({
    super.key,
    required this.onSelect,
    required this.onClose,
    this.width = 320,
  });

  /// Exposed so a test can find this exact node rather than any other
  /// `Semantics` widget an ancestor happens to build.
  static const Key liveRegionKey = Key('composer_emoji_browse_announcer');

  final ValueChanged<String> onSelect;
  final VoidCallback onClose;
  final double width;

  @override
  ConsumerState<ComposerEmojiPicker> createState() =>
      _ComposerEmojiPickerState();
}

class _ComposerEmojiPickerState extends ConsumerState<ComposerEmojiPicker> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _scrollController = ScrollController();
  final _searchGrid = EmojiGridNavigator();
  String _query = '';
  int _highlighted = 0;
  List<PickerEmoji> _visible = const [];
  List<EmojiSection> _sections = const [];

  /// Whichever tile the pointer sits over right now, by token rather than
  /// by identity - a rebuild recomputes fresh [PickerEmoji] instances, so
  /// comparing objects would drop a hover the moment anything else changed.
  String? _hoverToken;
  String? _pressToken;

  /// The rail's own last jump, best-effort only: nothing here tracks scroll
  /// position live, so this goes stale the moment a member scrolls by hand
  /// rather than tapping the rail again. See `emoji_sectioned_grid.dart`.
  EmojiCategory? _jumpedTo;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    _searchGrid.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() {
      _query = value;
      _highlighted = 0;
    });
  }

  double get _gridCrossAxisExtent =>
      widget.width -
      EmojiCategoryRail.width -
      AppSpacing.s4 -
      2 * EmojiSectionedGrid.gridInset;

  /// One cell left (-1) or right (+1), stopping at either end.
  void _moveCell(int delta) {
    if (_visible.isEmpty) return;
    _highlight((_highlighted + delta).clamp(0, _visible.length - 1));
  }

  /// One row up (-1) or down (+1); sections are stepped across, a search's
  /// flat grid by its own column count.
  void _moveRow(int rows) {
    if (_visible.isEmpty) return;
    final searching = _query.trim().isNotEmpty;
    _highlight(
      searching
          ? _searchGrid.step(_highlighted, _visible.length, rows)
          : EmojiSectionNavigation(
              sections: _sections,
              crossAxisExtent: _gridCrossAxisExtent,
            ).stepRow(_highlighted, rows),
    );
  }

  void _highlight(int index) {
    if (_query.trim().isEmpty && _scrollController.hasClients) {
      final position = _scrollController.position;
      _scrollController.jumpTo(
        EmojiSectionNavigation(
          sections: _sections,
          crossAxisExtent: _gridCrossAxisExtent,
        ).reveal(index, position.pixels, position.viewportDimension),
      );
    }
    setState(() => _highlighted = index);
  }

  void _pick(PickerEmoji emoji) {
    unawaited(ref.read(recentEmojiProvider.notifier).use(emoji.token));
    widget.onSelect(emoji.token);
  }

  void _pickHighlighted() {
    if (_visible.isEmpty) return;
    _pick(_visible[_highlighted]);
  }

  void _setHover(PickerEmoji emoji, bool active) {
    setState(() => _hoverToken = active ? emoji.token : null);
  }

  void _setPress(PickerEmoji emoji, bool active) {
    setState(() => _pressToken = active ? emoji.token : null);
  }

  /// Hover wins over a held press, which wins over the keyboard's own
  /// highlight - the order a pointer and a finger would actually take over
  /// from whatever arrow keys last landed on.
  PickerEmoji? _preview() {
    for (final token in [_hoverToken, _pressToken]) {
      if (token == null) continue;
      for (final entry in _visible) {
        if (entry.token == token) return entry;
      }
    }
    if (_visible.isEmpty) return null;
    return _visible[_highlighted];
  }

  void _jumpTo(EmojiCategory category, List<EmojiSection> sections) {
    final offset = emojiSectionScrollOffset(
      category: category,
      sections: sections,
      crossAxisExtent: _gridCrossAxisExtent,
    );
    setState(() => _jumpedTo = category);
    unawaited(
      _scrollController.animateTo(
        offset,
        duration: AppMotion.base,
        curve: AppMotion.entrance,
      ),
    );
  }

  /// What a screen reader should hear once the view settles: a search's own
  /// result count, or that browsing is open at all - there is no single
  /// "current category" left to announce once every section is on screen
  /// at once.
  String _announcement(bool searching, int resultCount) {
    if (!searching) return 'Browse all emoji.';
    return resultCount == 0
        ? 'No matches.'
        : '$resultCount ${resultCount == 1 ? 'result' : 'results'} found.';
  }

  Map<ShortcutActivator, VoidCallback> _bindings() {
    final close = activatorFor(AppAction.escape);
    return {
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => _moveRow(1),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => _moveRow(-1),
      // Left and Right stay the search field's caret keys once it has text.
      if (_query.isEmpty) ...{
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _moveCell(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _moveCell(-1),
      },
      if (close != null) close: widget.onClose,
    };
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final recent = ref.watch(recentEmojiProvider);
    final custom =
        ref.watch(customEmojiProvider).valueOrNull ?? const <CustomEmoji>[];
    final searching = _query.trim().isNotEmpty;
    final sections = pickerSections(recent: recent, custom: custom);
    final results = searching
        ? pickerResults(
            query: _query,
            // Ignored while searching; pickerResults only consults it otherwise.
            category: EmojiCategory.smileysEmotion,
            recent: recent,
            custom: custom,
          )
        : [for (final section in sections) ...section.emoji];
    _visible = results;
    _sections = sections;
    if (_highlighted >= results.length) {
      _highlighted = results.isEmpty ? 0 : results.length - 1;
    }

    return CallbackShortcuts(
      bindings: _bindings(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Invisible live region: the silently-repainting grid never voices a result count or that browsing is open on its own.
          Semantics(
            key: ComposerEmojiPicker.liveRegionKey,
            liveRegion: true,
            label: _announcement(searching, results.length),
            child: const SizedBox.shrink(),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s8),
            child: AppInput(
              controller: _searchController,
              focusNode: _searchFocus,
              autofocus: true,
              placeholder: 'Search emoji',
              icon: Icon(
                AppIcons.search,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              onChanged: _onQueryChanged,
              onSubmitted: (_) => _pickHighlighted(),
              semanticLabel: 'Search emoji',
            ),
          ),
          const AppMenuDivider(),
          SizedBox(
            height: _browseHeight,
            child: searching
                ? _searchResults(results, tokens)
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      EmojiCategoryRail(
                        categories: [for (final s in sections) s.category],
                        selected:
                            _jumpedTo ??
                            (sections.isEmpty ? null : sections.first.category),
                        onSelect: (category) => _jumpTo(category, sections),
                      ),
                      const SizedBox(width: AppSpacing.s4),
                      Expanded(
                        child: EmojiSectionedGrid(
                          controller: _scrollController,
                          sections: sections,
                          highlighted: _highlighted,
                          onTap: _pick,
                          onHoverChange: _setHover,
                          onPressChange: _setPress,
                        ),
                      ),
                    ],
                  ),
          ),
          const AppMenuDivider(),
          EmojiPreviewFooter(emoji: _preview()),
        ],
      ),
    );
  }

  Widget _searchResults(List<PickerEmoji> results, AppTokens tokens) {
    if (results.isEmpty) {
      return Center(
        child: Text(
          'No matches.',
          style: AppText.body.copyWith(color: tokens.textSecondary),
        ),
      );
    }
    return EmojiGrid(
      navigator: _searchGrid,
      emoji: results,
      highlighted: _highlighted,
      onTap: _pick,
      onHoverChange: _setHover,
      onPressChange: _setPress,
    );
  }
}
