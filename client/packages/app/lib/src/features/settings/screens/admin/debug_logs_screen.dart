// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Debug logs members sent to the admins, newest first: `GET /debug-logs`.
/// Requires MANAGE_SERVER, the same bit the pane is gated on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../routing/routes.dart';
import '../../providers/debug_logs_controller.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import 'debug_log_row.dart';
import 'reports_load_more_row.dart';

class DebugLogsScreen extends StatelessWidget {
  const DebugLogsScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Debug logs',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    scrollable: false,
    child: DebugLogsPane(),
  );
}

/// The received logs, embeddable as a Space settings pane as well as routed.
class DebugLogsPane extends ConsumerWidget {
  const DebugLogsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(debugLogsControllerProvider);
    final controller = ref.read(debugLogsControllerProvider.notifier);
    final items = logs.items;

    return AppAsyncView<List<api.DebugLogEntry>>(
      value: AppAsyncState(
        data: logs.loading && items.isEmpty ? null : items,
        error: items.isEmpty ? logs.error : null,
      ),
      errorMessage: 'Could not load the debug logs.',
      onRetry: controller.refresh,
      data: (context, list) => ListView(
        children: [
          SettingsSectionCard(
            title: 'Debug logs',
            description: 'Sent by members and kept for 30 days.',
            children: [
              if (list.isEmpty)
                const SettingsEmptyState(
                  icon: AppIcons.debugLog,
                  title: 'No debug logs received',
                )
              else
                for (final entry in list)
                  DebugLogRow(key: ValueKey(entry.id), entry: entry),
            ],
          ),
          if (list.isNotEmpty && (logs.more || logs.error != null))
            ReportsLoadMoreRow(
              loading: logs.loading,
              error: logs.error,
              onTap: controller.loadMore,
            ),
        ],
      ),
    );
  }
}
