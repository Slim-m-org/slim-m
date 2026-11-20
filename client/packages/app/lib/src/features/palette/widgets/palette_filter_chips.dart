// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette's committed filters, one chip each under the search field.
/// A chip is its own remove button, reached by Left from the field's start.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../messages/providers/message_search_query.dart';
import 'palette_filter_suggestions.dart';

class PaletteFilterChips extends StatefulWidget {
  const PaletteFilterChips({
    super.key,
    required this.filters,
    required this.onRemove,
    required this.onExit,
    this.touch = false,
  });

  final List<SearchFilter> filters;
  final ValueChanged<SearchFilter> onRemove;

  /// Right past the last chip, or removing the only one, goes back to the field.
  final VoidCallback onExit;
  final bool touch;

  @override
  State<PaletteFilterChips> createState() => PaletteFilterChipsState();
}

/// Left arrow at the start of the field focuses the last chip; Left and Right
/// move between chips; Backspace or Delete removes the focused one.
class PaletteFilterChipsState extends State<PaletteFilterChips> {
  final List<FocusNode> _nodes = [];

  /// Takes focus onto the last chip, if there is one.
  void focusLast() => _focus(widget.filters.length - 1);

  void _focus(int index) {
    if (index < 0 || index >= _nodes.length) return widget.onExit();
    _nodes[index].requestFocus();
  }

  void _syncNodes() {
    while (_nodes.length < widget.filters.length) {
      _nodes.add(FocusNode(debugLabel: 'palette-filter-${_nodes.length}'));
    }
    while (_nodes.length > widget.filters.length) {
      _nodes.removeLast().dispose();
    }
  }

  KeyEventResult _onKey(int index, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _focus(index == 0 ? 0 : index - 1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _focus(index + 1);
    } else if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      widget.onRemove(widget.filters[index]);
      // After the rebuild, so the chip before the removed one still exists to take focus.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => mounted ? _focus(index - 1) : null,
      );
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncNodes();
    return Wrap(
      spacing: AppSpacing.s8,
      runSpacing: AppSpacing.s8,
      children: [
        for (final (i, filter) in widget.filters.indexed)
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (_, event) => _onKey(i, event),
            child: _FilterChip(
              filter: filter,
              focusNode: _nodes[i],
              touch: widget.touch,
              onRemove: () => widget.onRemove(filter),
            ),
          ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.filter,
    required this.focusNode,
    required this.touch,
    required this.onRemove,
  });

  final SearchFilter filter;
  final FocusNode focusNode;
  final bool touch;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final shown = filter.label ?? filter.value;
    return AppTouchHitArea(
      touch: touch,
      child: FocusableTapTarget(
        key: ValueKey('palette-filter-${filter.typed}'),
        focusNode: focusNode,
        onTap: onRemove,
        semanticLabel: 'Remove filter ${filter.key.word}: $shown',
        ringRadius: AppRadii.full,
        builder: (context, focused, hovered) => Container(
          height: touch ? AppSizes.icon32 : AppSizes.icon24,
          padding: const EdgeInsets.only(
            left: AppSpacing.s8,
            right: AppSpacing.s4,
          ),
          decoration: BoxDecoration(
            color: hovered ? tokens.surfaceSunken : tokens.surfaceBase,
            border: Border.all(color: tokens.borderStrong),
            borderRadius: BorderRadius.circular(AppRadii.full),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: AppSpacing.s4,
            children: [
              Icon(
                searchKeyIcon(filter.key),
                size: AppSizes.icon12,
                color: tokens.textSecondary,
              ),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${filter.key.word}:',
                        style: AppText.code.copyWith(
                          fontSize: AppText.caption.fontSize,
                          color: tokens.textSecondary,
                        ),
                      ),
                      TextSpan(
                        text: ' $shown',
                        style: AppText.caption.copyWith(
                          color: tokens.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                AppIcons.dismiss,
                size: AppSizes.icon12,
                color: hovered ? tokens.textPrimary : tokens.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
