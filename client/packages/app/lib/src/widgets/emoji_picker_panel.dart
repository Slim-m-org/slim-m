// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picker surface itself: search, category tabs, and the grid they
/// filter. Its two entry points (a hover-anchored button and a bottom sheet)
/// live in `emoji_picker.dart`, which re-exports this.
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

/// The panel's own measured width, like the command palette's `_paletteWidth`
/// beside it; neither is on the spacing grid.
const double pickerWidth = 320;
const double _gridHeight = 260;

/// Exposed on its own so a test can pump it without the button's overlay
/// plumbing around it.
class EmojiPickerPanel extends ConsumerStatefulWidget {
  const EmojiPickerPanel({
    super.key,
    required this.onSelect,
    required this.onClose,
    this.autofocusSearch = true,
    this.width = pickerWidth,
  });

  /// Exposed so a test can find this exact node rather than any other
  /// `Semantics` widget an ancestor happens to build.
  static const Key liveRegionKey = Key('emoji_picker_announcer');

  /// Called with the picked emoji's token: the character itself for a unicode
  /// emoji, `:name:` for one of the deployment's own.
  final ValueChanged<String> onSelect;
  final VoidCallback onClose;

  /// Off in a sheet: an autofocused search field raises the soft keyboard
  /// over the grid before the user has seen any of it.
  final bool autofocusSearch;

  /// Overridable so the panel can shrink to a narrow phone rather than
  /// overflow its sheet.
  final double width;

  @override
  ConsumerState<EmojiPickerPanel> createState() => _EmojiPickerPanelState();
}

class _EmojiPickerPanelState extends ConsumerState<EmojiPickerPanel> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _grid = EmojiGridNavigator();
  String _query = '';

  /// Null until a tab is tapped, so the panel can open on whichever one
  /// leads; see [effectiveCategory].
  EmojiCategory? _category;

  /// -1 is "no cell highlighted", the state the picker opens in: index 0
  /// would otherwise paint an accent border on the first tile the moment
  /// the panel appears, before the user has searched or pressed a key. A
  /// search highlights its first result (so Enter picks it) and an arrow
  /// key moves into the grid; browsing a category idles at -1.
  int _highlighted = -1;

  /// The last frame's flat result list, so a key handler (which runs outside
  /// build) can act on exactly what is on screen, the same convention the
  /// command palette uses for its own `_visible`.
  List<PickerEmoji> _visible = const [];

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _grid.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() {
      _query = value;
      // First result highlighted while searching so Enter picks it; none when the query is empty.
      _highlighted = value.trim().isEmpty ? -1 : 0;
    });
  }

  void _selectCategory(EmojiCategory category) {
    setState(() {
      _category = category;
      _query = '';
      _searchController.clear();
      _highlighted = -1;
    });
  }

  /// One row up (-1) or down (+1); see [EmojiGridNavigator.step].
  void _move(int rows) => setState(
    () => _highlighted = _grid.step(_highlighted, _visible.length, rows),
  );

  void _pick(PickerEmoji emoji) {
    unawaited(ref.read(recentEmojiProvider.notifier).use(emoji.token));
    widget.onSelect(emoji.token);
  }

  void _pickHighlighted() {
    if (_visible.isEmpty || _highlighted < 0) return;
    _pick(_visible[_highlighted]);
  }

  /// What a screen reader should hear once the grid settles: which category
  /// it is now looking at, or a search's own result count / "no matches".
  String _announcement(
    bool searching,
    EmojiCategory category,
    List<PickerEmoji> results,
  ) {
    if (!searching) return '${category.label} emoji.';
    final count = results.length;
    return count == 0
        ? 'No matches.'
        : '$count ${count == 1 ? 'result' : 'results'} found.';
  }

  Map<ShortcutActivator, VoidCallback> _bindings() {
    final close = activatorFor(AppAction.escape);
    return {
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
      if (close != null) close: widget.onClose,
    };
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final recent = ref.watch(recentEmojiProvider);

    /// A deployment with none, one still loading, and one whose list could
    /// not be fetched are all the same picker: the one there has always been.
    final custom =
        ref.watch(customEmojiProvider).valueOrNull ?? const <CustomEmoji>[];
    final searching = _query.trim().isNotEmpty;
    final category = effectiveCategory(_category, hasCustom: custom.isNotEmpty);

    final results = pickerResults(
      query: _query,
      category: category,
      recent: recent,
      custom: custom,
    );
    _visible = results;
    if (_highlighted >= results.length) {
      _highlighted = results.isEmpty ? -1 : results.length - 1;
    }

    return CallbackShortcuts(
      bindings: _bindings(),
      child: Material(
        type: MaterialType.transparency,
        child: AppMenu(
          width: widget.width,
          children: [
            // Invisible live region: announces a category switch or a search's result count / "no matches", which the silently-repainting grid below never voices on its own.
            Semantics(
              key: EmojiPickerPanel.liveRegionKey,
              liveRegion: true,
              label: _announcement(searching, category, results),
              child: const SizedBox.shrink(),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s8),
              child: AppInput(
                controller: _searchController,
                focusNode: _searchFocus,
                autofocus: widget.autofocusSearch,
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
            if (!searching) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
                child: EmojiCategoryTabs(
                  categories: pickerTabs(
                    hasCustom: custom.isNotEmpty,
                    hasRecent: recent.isNotEmpty,
                  ),
                  selected: category,
                  onSelect: _selectCategory,
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
            ],
            const AppMenuDivider(),
            SizedBox(
              height: _gridHeight,
              child: results.isEmpty
                  ? Center(
                      child: Text(
                        'No matches.',
                        style: AppText.body.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    )
                  : EmojiGrid(
                      emoji: results,
                      highlighted: _highlighted,
                      navigator: _grid,
                      onTap: _pick,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
