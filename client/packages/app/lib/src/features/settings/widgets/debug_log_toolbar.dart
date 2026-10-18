// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The debug log's filters: search and level on one row when there is room,
/// stacked when there is not, and the area chips under them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_design_system/design_system.dart';

import '../../../diagnostics/debug_log.dart';
import '../../../diagnostics/debug_log_filter.dart';

/// Search and level share a row from this width up.
const double _sideBySideWidth = 560;

const _levels = <LogLevel?>[
  null,
  LogLevel.error,
  LogLevel.warning,
  LogLevel.info,
  LogLevel.debug,
];
const _levelLabels = ['All', 'Errors', 'Warnings', 'Info', 'Debug'];

int _count(List<DiagnosticEvent> all, LogLevel? level) =>
    level == null ? all.length : all.where((e) => e.level == level).length;

class DebugLogToolbar extends ConsumerStatefulWidget {
  const DebugLogToolbar({super.key});

  @override
  ConsumerState<DebugLogToolbar> createState() => _DebugLogToolbarState();
}

class _DebugLogToolbarState extends ConsumerState<DebugLogToolbar> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _update(DebugLogFilter next) =>
      ref.read(debugLogFilterProvider.notifier).state = next;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(debugLogProvider);
    final filter = ref.watch(debugLogFilterProvider);
    final tags = ({for (final e in all) e.source}.toList()..sort());

    final search = AppInput(
      controller: _search,
      placeholder: 'Search the log',
      semanticLabel: 'Search the log',
      size: AppInputSize.sm,
      icon: const Icon(AppIcons.search, size: AppSizes.icon16),
      onChanged: (v) => _update(filter.withQuery(v)),
    );
    final levels = AppSegmentedControl.inline(
      semanticLabel: 'Show level',
      options: [
        for (var i = 0; i < _levels.length; i++)
          AppSegmentedOption(
            label: '${_levelLabels[i]} ${_count(all, _levels[i])}',
          ),
      ],
      selectedIndex: _levels.indexOf(filter.level),
      onSegmentSelected: (i) => _update(filter.withLevel(_levels[i])),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AppSpacing.s8,
      children: [
        LayoutBuilder(
          builder: (context, box) => box.maxWidth >= _sideBySideWidth
              ? Row(
                  spacing: AppSpacing.s12,
                  children: [
                    Expanded(flex: 2, child: search),
                    Expanded(flex: 3, child: levels),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: AppSpacing.s8,
                  children: [search, levels],
                ),
        ),
        if (tags.length > 1)
          _AreaChips(
            tags: tags,
            selected: filter.tag,
            onSelected: (tag) => _update(filter.withTag(tag)),
          ),
      ],
    );
  }
}

class _AreaChips extends StatelessWidget {
  const _AreaChips({
    required this.tags,
    required this.selected,
    required this.onSelected,
  });

  final List<String> tags;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      container: true,
      label: 'Show area',
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpacing.s8,
        runSpacing: AppSpacing.s4,
        children: [
          Text(
            'Area',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          _AreaChip(
            label: 'All',
            selected: selected == null,
            onTap: () => onSelected(null),
          ),
          for (final tag in tags)
            _AreaChip(
              label: tag,
              selected: selected == tag,
              onTap: () => onSelected(selected == tag ? null : tag),
            ),
        ],
      ),
    );
  }
}

class _AreaChip extends StatelessWidget {
  const _AreaChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return FocusableTapTarget(
      key: ValueKey('area-$label'),
      onTap: onTap,
      selected: selected,
      semanticLabel: label,
      ringRadius: AppRadii.full,
      builder: (context, focused, hovered) => Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s12),
        decoration: BoxDecoration(
          color: selected
              ? tokens.accentSoft
              : hovered
              ? tokens.surfaceSunken
              : Colors.transparent,
          // Constant: an accent outline is reserved for focus (decision 0004).
          border: Border.all(color: tokens.borderSubtle),
          borderRadius: BorderRadius.circular(AppRadii.full),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: AppText.caption.copyWith(
                color: selected ? tokens.accent : tokens.textSecondary,
                fontWeight: selected ? AppWeights.semi : AppWeights.regular,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
