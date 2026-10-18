// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The debug log's body: what the app caught this session, newest first, and
/// the memory readout under it.
///
/// Shared by the inner page beside the settings nav on wide windows and the
/// standalone route a phone pushes, so the two cannot drift apart.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_design_system/design_system.dart';

import '../../../diagnostics/debug_log.dart';
import '../../../diagnostics/debug_log_filter.dart';
import '../../../providers/toasts.dart';
import 'debug_log_entry.dart';
import 'memory_diagnostics.dart';
import 'settings_section_header.dart';

/// Puts what the filter lets through on the clipboard, redacted, and says so.
Future<void> copyDebugLog(BuildContext context, WidgetRef ref) async {
  final report = ref
      .read(debugLogProvider.notifier)
      .asReport(ref.read(shownDebugLogProvider));
  await Clipboard.setData(ClipboardData(text: report));
  if (!context.mounted) return;
  ref
      .read(toastsProvider.notifier)
      .show('Debug log copied', severity: AppToastSeverity.success);
}

class DebugLogPage extends ConsumerStatefulWidget {
  const DebugLogPage({super.key});

  @override
  ConsumerState<DebugLogPage> createState() => _DebugLogPageState();
}

class _DebugLogPageState extends ConsumerState<DebugLogPage> {
  static const _levels = <LogLevel?>[
    null,
    LogLevel.error,
    LogLevel.warning,
    LogLevel.info,
    LogLevel.debug,
  ];
  static const _levelLabels = ['All', 'Errors', 'Warnings', 'Info', 'Debug'];

  static int _count(List<DiagnosticEvent> all, LogLevel? level) =>
      level == null ? all.length : all.where((e) => e.level == level).length;

  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(debugLogProvider);
    final filter = ref.watch(debugLogFilterProvider);
    final shown = ref.watch(shownDebugLogProvider);
    final tags = ({for (final e in entries) e.source}.toList()..sort());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'This session',
          description: entries.isEmpty
              ? 'Errors the app catches are collected here for bug reports.'
              : filter.isActive
              ? '${shown.length} of ${entries.length} shown, newest first.'
              : '${entries.length} logged, newest first.',
          children: [
            if (entries.isNotEmpty) _filters(filter, tags, entries),
            if (entries.isEmpty)
              const _AllClear()
            else if (shown.isEmpty)
              const _NoneOfThisLevel()
            else
              for (final entry in shown)
                DebugLogEntry(key: ObjectKey(entry), entry: entry),
          ],
        ),
        const MemoryDiagnostics(),
      ],
    );
  }

  Widget _filters(
    DebugLogFilter filter,
    List<String> tags,
    List<DiagnosticEvent> all,
  ) {
    void update(DebugLogFilter next) =>
        ref.read(debugLogFilterProvider.notifier).state = next;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AppSpacing.s12,
        children: [
          AppInput(
            controller: _search,
            placeholder: 'Search the log',
            semanticLabel: 'Search the log',
            icon: const Icon(AppIcons.search, size: AppSizes.icon16),
            onChanged: (v) => update(filter.withQuery(v)),
          ),
          AppSegmentedControl.inline(
            semanticLabel: 'Show level',
            options: [
              for (var i = 0; i < _levels.length; i++)
                AppSegmentedOption(
                  label: '${_levelLabels[i]} ${_count(all, _levels[i])}',
                ),
            ],
            selectedIndex: _levels.indexOf(filter.level),
            onSegmentSelected: (i) => update(filter.withLevel(_levels[i])),
          ),
          if (tags.length > 1)
            Wrap(
              spacing: AppSpacing.s8,
              runSpacing: AppSpacing.s8,
              children: [
                for (final tag in tags)
                  AppButton(
                    label: tag,
                    size: AppButtonSize.sm,
                    variant: filter.tag == tag
                        ? AppButtonVariant.soft
                        : AppButtonVariant.ghost,
                    onPressed: () =>
                        update(filter.withTag(filter.tag == tag ? null : tag)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _AllClear extends StatelessWidget {
  const _AllClear();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tokens.surfaceBase,
              border: Border.all(color: tokens.borderSubtle),
            ),
            child: Icon(
              AppIcons.check,
              size: AppSizes.icon20,
              color: tokens.status.online,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Nothing has gone wrong this session',
            textAlign: TextAlign.center,
            style: AppText.ui.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.medium,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoneOfThisLevel extends StatelessWidget {
  const _NoneOfThisLevel();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s24),
      child: Text(
        'Nothing matches this filter.',
        textAlign: TextAlign.center,
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}
