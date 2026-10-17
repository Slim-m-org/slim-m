// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings search: the field above the settings nav, its results, and the
/// highlight that walks someone from a result to the row it named.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/settings_index.dart';

/// The label of the row a search result just opened, for that row to find.
class SettingsHighlight extends InheritedNotifier<ValueNotifier<String?>> {
  const SettingsHighlight({
    super.key,
    required ValueNotifier<String?> super.notifier,
    required super.child,
  });

  static ValueNotifier<String?>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsHighlight>()?.notifier;
}

/// Wraps a settings row: when search opens it, scrolls it into view and
/// briefly tints it so the eye lands on the setting it searched for.
class SettingsHighlightTarget extends StatefulWidget {
  const SettingsHighlightTarget({
    super.key,
    required this.label,
    required this.child,
  });

  final String? label;
  final Widget child;

  @override
  State<SettingsHighlightTarget> createState() =>
      _SettingsHighlightTargetState();
}

class _SettingsHighlightTargetState extends State<SettingsHighlightTarget> {
  static const _hold = Duration(milliseconds: 1400);
  bool _lit = false;
  Timer? _fade;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final highlight = SettingsHighlight.maybeOf(context);
    if (highlight == null || widget.label == null) return;
    if (highlight.value != widget.label || _lit) return;
    _lit = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          context,
          alignment: 0.3,
          duration: AppMotion.reduced(context, AppMotion.base),
        ),
      );
      _fade = Timer(_hold, () {
        if (!mounted) return;
        setState(() => _lit = false);
        if (highlight.value == widget.label) highlight.value = null;
      });
    });
  }

  @override
  void dispose() {
    _fade?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AnimatedContainer(
      duration: AppMotion.reduced(context, AppMotion.slow),
      decoration: BoxDecoration(
        color: _lit
            ? tokens.accentSoft
            : tokens.accentSoft.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: widget.child,
    );
  }
}

/// The search field over [child] (the nav), swapped for results while typing.
class SettingsSearchArea extends StatefulWidget {
  const SettingsSearchArea({
    super.key,
    required this.entries,
    required this.paneLabels,
    required this.onOpen,
    required this.padding,
    required this.child,
  });

  final List<SettingsEntry> entries;

  /// Pane id to its nav label, so a result can say which section it is in.
  final Map<String, String> paneLabels;
  final ValueChanged<SettingsEntry> onOpen;
  final EdgeInsets padding;
  final Widget child;

  @override
  State<SettingsSearchArea> createState() => _SettingsSearchAreaState();
}

class _SettingsSearchAreaState extends State<SettingsSearchArea> {
  final _controller = TextEditingController();
  List<SettingsEntry> _results = const [];
  int _cursor = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search(String query) => setState(() {
    _results = searchSettings(query, widget.entries);
    _cursor = 0;
  });

  void _clear() {
    _controller.clear();
    _search('');
  }

  void _open(SettingsEntry entry) {
    _clear();
    widget.onOpen(entry);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && _controller.text.isNotEmpty) {
      _clear();
      return KeyEventResult.handled;
    }
    if (_results.isEmpty) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _cursor = (_cursor + 1) % _results.length);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _cursor = (_cursor - 1) % _results.length);
    } else if (key == LogicalKeyboardKey.enter) {
      _open(_results[_cursor]);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final searching = _controller.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: widget.padding.copyWith(bottom: AppSpacing.s8),
          child: Focus(
            onKeyEvent: _onKey,
            child: AppInput(
              key: const Key('settings-search'),
              controller: _controller,
              placeholder: 'Search settings',
              icon: Icon(
                AppIcons.search,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              size: AppInputSize.sm,
              semanticLabel: 'Search settings',
              onChanged: _search,
            ),
          ),
        ),
        Expanded(
          child: !searching
              ? widget.child
              : _results.isEmpty
              ? Padding(
                  padding: widget.padding,
                  child: Text(
                    'No settings match',
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                )
              : ListView(
                  padding: widget.padding.copyWith(top: 0),
                  children: [
                    for (final (i, entry) in _results.indexed)
                      AppListRow(
                        key: ValueKey(
                          'settings-result-${entry.pane}-${entry.label}',
                        ),
                        label: entry.label,
                        subtitle: _where(entry),
                        selected: i == _cursor,
                        onTap: () => _open(entry),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  String _where(SettingsEntry entry) {
    final section = widget.paneLabels[entry.pane] ?? entry.pane;
    final description = entry.description;
    return description == null ? section : '$section · $description';
  }
}
