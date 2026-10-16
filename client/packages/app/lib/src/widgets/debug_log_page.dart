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
import 'package:slimm_design_system/design_system.dart';

import '../diagnostics/debug_log.dart';
import '../providers/toasts.dart';
import 'debug_log_entry.dart';
import 'memory_diagnostics.dart';
import 'settings_section_header.dart';

/// Puts the whole log on the clipboard and says so.
Future<void> copyDebugLog(BuildContext context, WidgetRef ref) async {
  final report = ref.read(debugLogProvider.notifier).asReport();
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
  DiagnosticSeverity? _filter;

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(debugLogProvider);
    final errors = _count(entries, DiagnosticSeverity.error);
    final warnings = _count(entries, DiagnosticSeverity.warning);
    final shown = _filter == null
        ? entries
        : [
            for (final e in entries)
              if (e.level == _filter) e,
          ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'This session',
          description: entries.isEmpty
              ? 'Errors the app catches are collected here for bug reports.'
              : '${entries.length} caught, newest first.',
          trailing: entries.isEmpty
              ? null
              : AppSegmentedControl.inline(
                  semanticLabel: 'Show',
                  options: [
                    AppSegmentedOption(label: 'All ${entries.length}'),
                    AppSegmentedOption(label: 'Errors $errors'),
                    AppSegmentedOption(label: 'Warnings $warnings'),
                  ],
                  selectedIndex: switch (_filter) {
                    null => 0,
                    DiagnosticSeverity.error => 1,
                    _ => 2,
                  },
                  onSegmentSelected: (i) => setState(
                    () => _filter = switch (i) {
                      1 => DiagnosticSeverity.error,
                      2 => DiagnosticSeverity.warning,
                      _ => null,
                    },
                  ),
                ),
          children: [
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

  static int _count(List<DiagnosticEvent> entries, DiagnosticSeverity level) =>
      entries.where((e) => e.level == level).length;
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
        'Nothing of this kind was caught.',
        textAlign: TextAlign.center,
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}
