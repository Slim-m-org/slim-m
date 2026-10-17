// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's code action: a short list of what to insert, inline code
/// or a fenced block in a chosen language, filtered as you type.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/code_block_runner.dart';
import 'composer_extras.dart' show usesSoftKeyboard;
import 'message_code_langs.dart' show langSpecs;

/// One row of the picker: [language] is null for inline code and `''` for a
/// block with no language.
class CodeInsertChoice {
  const CodeInsertChoice._(this.label, this.language);

  static const inline = CodeInsertChoice._('Inline code', null);
  static const plainBlock = CodeInsertChoice._('Code block', '');

  factory CodeInsertChoice.block(String language) =>
      CodeInsertChoice._(_labelFor(language), language);

  final String label;
  final String? language;

  bool get isInline => language == null;
}

const Map<String, String> _labels = {
  'bash': 'Shell',
  'c': 'C',
  'cpp': 'C++',
  'csharp': 'C#',
  'javascript': 'JavaScript',
  'json': 'JSON',
  'sql': 'SQL',
  'typescript': 'TypeScript',
  'yaml': 'YAML',
};

String _labelFor(String language) =>
    _labels[language] ??
    (language.isEmpty
        ? language
        : '${language[0].toUpperCase()}${language.substring(1)}');

/// Null when dismissed. [allowInline] is false when the selection spans
/// lines, which inline code cannot hold.
Future<CodeInsertChoice?> showCodeInsertPicker(
  BuildContext context, {
  required bool allowInline,
}) => showAppSheet<CodeInsertChoice>(
  context,
  maxWidth: 360,
  builder: (_) => CodeInsertPicker(allowInline: allowInline),
);

class CodeInsertPicker extends ConsumerStatefulWidget {
  const CodeInsertPicker({super.key, required this.allowInline});

  final bool allowInline;

  @override
  ConsumerState<CodeInsertPicker> createState() => _CodeInsertPickerState();
}

class _CodeInsertPickerState extends ConsumerState<CodeInsertPicker> {
  final _filter = TextEditingController();
  // On the field's own node: the field consumes the arrows before an ancestor sees them.
  late final _filterFocus = FocusNode(onKeyEvent: (_, event) => _onKey(event));
  int _highlighted = 0;
  List<CodeInsertChoice> _shown = const [];

  @override
  void dispose() {
    _filter.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  List<(CodeInsertChoice, bool runs)> _rows() {
    final runners = ref.watch(codeBlockRunnerProvider).valueOrNull ?? const [];
    final languages =
        {
          ...langSpecs.keys,
          for (final r in runners)
            if (r.language case final l? when l.trim().isNotEmpty)
              l.trim().toLowerCase(),
        }.toList()..sort(
          (a, b) =>
              _labelFor(a).toLowerCase().compareTo(_labelFor(b).toLowerCase()),
        );
    final query = _filter.text.trim().toLowerCase();
    bool matches(CodeInsertChoice c) =>
        query.isEmpty ||
        c.label.toLowerCase().contains(query) ||
        (c.language?.contains(query) ?? false);
    return [
      if (widget.allowInline) (CodeInsertChoice.inline, false),
      (CodeInsertChoice.plainBlock, false),
      for (final l in languages)
        (CodeInsertChoice.block(l), matchCodeBlockRunner(runners, l) != null),
    ].where((row) => matches(row.$1)).toList();
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => 1,
      LogicalKeyboardKey.arrowUp => -1,
      _ => 0,
    };
    if (step == 0 || _shown.isEmpty) return KeyEventResult.ignored;
    setState(() => _highlighted = (_highlighted + step) % _shown.length);
    return KeyEventResult.handled;
  }

  /// Reads the state, not the last build: a key can land before the redraw.
  void _submit(String text) => Navigator.of(context).pop(
    _shown.isEmpty
        ? CodeInsertChoice.block(text.trim().toLowerCase())
        : _shown[_highlighted.clamp(0, _shown.length - 1)],
  );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final rows = _rows();
    _shown = [for (final row in rows) row.$1];
    final highlighted = rows.isEmpty
        ? -1
        : _highlighted.clamp(0, rows.length - 1);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s12,
            ),
            child: Text('Insert code', style: AppText.heading),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s8,
            ),
            child: AppInput(
              controller: _filter,
              focusNode: _filterFocus,
              // A soft keyboard would cover the list a tap could choose from.
              autofocus: !usesSoftKeyboard(context),
              placeholder: 'Filter languages',
              semanticLabel: 'Filter languages',
              icon: const Icon(AppIcons.search),
              onChanged: (_) => setState(() => _highlighted = 0),
              onSubmitted: _submit,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (i, (choice, runs)) in rows.indexed)
                  AppListRow(
                    label: choice.label,
                    // Only the two kinds carry a glyph; a glyph per language would be noise.
                    leading: choice.language?.isNotEmpty ?? false
                        ? const SizedBox(width: AppSizes.icon16)
                        : Icon(
                            choice.isInline
                                ? AppIcons.code
                                : AppIcons.codeBlock,
                            size: AppSizes.icon16,
                            color: tokens.textSecondary,
                          ),
                    meta: choice.isInline ? '`code`' : null,
                    trailing: runs
                        ? const AppBadge(
                            variant: AppBadgeVariant.tag,
                            label: 'Runs',
                            semanticLabel: 'Can run',
                          )
                        : null,
                    selected: i == highlighted,
                    onTap: () => Navigator.of(context).pop(choice),
                  ),
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.s16),
                    child: Text(
                      'No match. Enter tags the block '
                      '"${_filter.text.trim().toLowerCase()}".',
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
        ],
      ),
    );
  }
}
