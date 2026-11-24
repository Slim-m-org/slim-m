// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How much the server logs, and a download of its newest lines (decision
/// 0129), at the top of the Space's Debug logs pane.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/providers.dart';
import '../../../../widgets/load_error_block.dart';
import '../../../../widgets/optimistic_setting_state.dart';
import '../../../../widgets/run_guarded.dart';
import '../../providers/settings_actions.dart';
import '../../providers/space_settings.dart';
import '../../providers/theme_file_io.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_segmented_block.dart';

const _modes = <(String, ServerLogMode)>[
  ('Off', ServerLogMode.off),
  ('Compact', ServerLogMode.compact),
  ('Verbose', ServerLogMode.verbose),
];

String _consequence(ServerLogMode mode) => switch (mode) {
  ServerLogMode.off => 'Startup, warnings and errors.',
  ServerLogMode.compact => 'One line per call, sync, sign-in and media event.',
  ServerLogMode.verbose => 'Everything. Older logs are cleared sooner.',
};

String _fileName(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'server-log-${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}.txt';
}

class ServerLoggingSection extends ConsumerStatefulWidget {
  const ServerLoggingSection({super.key});

  @override
  ConsumerState<ServerLoggingSection> createState() =>
      _ServerLoggingSectionState();
}

class _ServerLoggingSectionState extends ConsumerState<ServerLoggingSection>
    with
        GuardedActionState<ServerLoggingSection>,
        OptimisticSettingState<ServerLoggingSection, ServerLogMode> {
  bool _downloading = false;
  bool _noFiles = false;

  Future<void> _set(ServerLogMode mode) => saveOptimistic(
    mode,
    whatFailed: 'change server logging',
    action: () => ref
        .read(settingsActionsProvider)
        .setSpaceSettings(SpaceSettingsUpdate(debugLogging: mode)),
    refresh: spaceSettingsProvider,
  );

  Future<void> _download() async {
    setState(() => _downloading = true);
    final api = ref.read(apiProvider);
    final save = ref.read(themeFileSaverProvider);
    var noFiles = false;
    await guard(
      whatFailed: 'download the server logs',
      action: () async {
        final log = await api.serverLogs();
        noFiles = log == null;
        if (log == null) return;
        await save(_fileName(DateTime.now()), log);
      },
    );
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _noFiles = noFiles;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(spaceSettingsProvider);
    ref.listen(spaceSettingsProvider, (_, next) => retireOptimistic(next));
    final current = optimistic ?? settings.valueOrNull?.debugLogging;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Server logging',
          description: 'How much the server records, for finding bugs.',
          children: [
            SettingsSegmentedBlock(
              semanticLabel: 'Server logging detail',
              labels: [for (final mode in _modes) mode.$1],
              selectedIndex: _modes.indexWhere((m) => m.$2 == current),
              disabled: saving || current == null,
              onSelected: (i) => _set(_modes[i].$2),
            ),
            if (current != null)
              SettingsSubRow(label: _consequence(current), indented: false),
            if (settings.hasError && current == null)
              LoadErrorBlock(
                message: 'Could not load this setting.',
                onRetry: () => ref.invalidate(spaceSettingsProvider),
              ),
            SettingsActionRow(
              message: _noFiles
                  ? 'This server keeps no log files.'
                  : 'Newest lines, kept across restarts.',
              action: AppButton(
                label: 'Download',
                icon: AppIcons.download,
                size: AppButtonSize.sm,
                busy: _downloading,
                semanticLabel: 'Download server logs',
                onPressed: () => unawaited(_download()),
              ),
            ),
          ],
        ),
        SettingsSaveFeedback(
          tick: successTick,
          error: actionError,
          onDismissError: clearActionError,
        ),
      ],
    );
  }
}
