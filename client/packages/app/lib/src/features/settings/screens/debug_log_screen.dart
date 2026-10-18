// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The debug log as its own screen, for a phone: wide windows show the same
/// [DebugLogPage] inside the Troubleshooting pane instead.
///
/// Goes through [SettingsScreenScaffold] like its siblings so it carries the
/// named "Back to X" tooltip, the only thing that says where the arrow goes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../diagnostics/debug_log.dart';
import '../../../diagnostics/debug_log_filter.dart';
import '../../../routing/routes.dart';
import '../widgets/debug_log_page.dart';
import 'settings_screen_scaffold.dart';

class DebugLogScreen extends ConsumerWidget {
  const DebugLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final empty = ref.watch(debugLogProvider).isEmpty;

    return SettingsScreenScaffold(
      title: 'Debug log',
      backTooltip: 'Back to settings',
      backFallback: Routes.personalSettings,
      actions: [
        IconButton(
          icon: const Icon(AppIcons.copy),
          tooltip: ref.watch(debugLogFilterProvider).isActive
              ? 'Copy shown'
              : 'Copy all',
          onPressed: empty ? null : () => unawaited(copyDebugLog(context, ref)),
        ),
        IconButton(
          icon: const Icon(AppIcons.delete),
          tooltip: 'Clear',
          onPressed: empty ? null : ref.read(debugLogProvider.notifier).clear,
        ),
      ],
      child: const DebugLogPage(),
    );
  }
}
