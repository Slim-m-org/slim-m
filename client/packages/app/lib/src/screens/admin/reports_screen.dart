// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The moderation queue (`GET /reports`, `PATCH /reports/{id}`) and, beside
/// it, the moderation-history feed (`GET /reports/history`, MOD4): who was
/// removed, timed out, or restored, by whom, and when - see
/// docs/decisions/0015-moderation-audit-log.md for why that record exists.
/// The queue requires MANAGE_MESSAGES and the history either that or
/// VIEW_MODERATION_HISTORY, so a holder of only the second sees history alone;
/// the server refuses either request regardless.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../permissions.dart';
import '../../providers/admin_providers.dart' show myPermissionsProvider;
import '../../providers/reports_controller.dart';
import '../../routing/routes.dart';
import '../settings_screen_scaffold.dart';
import 'report_card.dart';
import 'report_history_pane.dart';
import 'reports_load_more_row.dart';
import '../../widgets/settings_empty.dart';

/// Whether [permissions] reads history but cannot read the open queue.
bool reportsHistoryOnly(int permissions) =>
    !permissions.hasPermission(Perm.manageMessages) &&
    permissions.hasPermission(Perm.viewModerationHistory);

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsScreenScaffold(
    title: 'Reports',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    scrollable: false,
    padding: EdgeInsets.zero,
    child: ReportsPane(
      historyOnly: reportsHistoryOnly(ref.watch(myPermissionsProvider)),
    ),
  );
}

/// The tabbed pane itself, embeddable as a Space settings pane as well as
/// routed: the open queue and, beside it, its history. Which tab is showing
/// is local widget state rather than a provider - nothing outside this pane
/// needs to know, and it is not worth surviving a navigation away and back.
///
/// Both tabs stay mounted in an [IndexedStack] rather than swapped
/// conditionally: each pane's controller is `autoDispose`, so tearing one
/// down every time its tab loses focus would refetch its whole first page
/// on every switch back.
class ReportsPane extends StatefulWidget {
  const ReportsPane({super.key, this.historyOnly = false});

  /// Shows only the history feed, for a caller who cannot read the open queue.
  final bool historyOnly;

  @override
  State<ReportsPane> createState() => _ReportsPaneState();
}

class _ReportsPaneState extends State<ReportsPane> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.historyOnly) return const ReportHistoryPane();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            AppSpacing.s16,
            AppSpacing.s16,
            AppSpacing.s8,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: AppSegmentedControl.inline(
              semanticLabel: 'Reports view',
              options: const [
                AppSegmentedOption(label: 'Open'),
                AppSegmentedOption(label: 'History'),
              ],
              selectedIndex: _tab,
              onSegmentSelected: (i) => setState(() => _tab = i),
            ),
          ),
        ),
        Expanded(
          // See this pane's own class doc for why this is an IndexedStack.
          child: IndexedStack(
            index: _tab,
            children: const [_OpenQueuePane(), ReportHistoryPane()],
          ),
        ),
      ],
    );
  }
}

/// The open queue: unchanged from before the History tab existed, just no
/// longer the whole of [ReportsPane].
class _OpenQueuePane extends ConsumerWidget {
  const _OpenQueuePane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = ref.watch(reportsControllerProvider);
    final controller = ref.read(reportsControllerProvider.notifier);
    return AppAsyncView<List<api.Report>>(
      // Only when there is nothing to show instead; see ReportsLoadMoreRow.
      value: AppAsyncState(
        data: reports.loading && reports.reports.isEmpty
            ? null
            : reports.reports,
        error: reports.reports.isEmpty ? reports.error : null,
      ),
      errorMessage: 'Could not load reports.',
      onRetry: controller.refresh,
      center: false,
      data: (context, list) => list.isEmpty
          ? ListView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
              children: const [SettingsEmpty('The queue is empty.')],
            )
          : ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.s16),
              // One trailing row when the last page came back full; see the controller.
              itemCount: reports.more || reports.error != null
                  ? list.length + 1
                  : list.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppSpacing.s12),
              itemBuilder: (context, i) => i == list.length
                  ? ReportsLoadMoreRow(
                      loading: reports.loading,
                      error: reports.error,
                      failureMessage: 'Could not load more reports.',
                      onTap: controller.loadMore,
                    )
                  // Keyed by id, or a shortened page hands the next report the previous card's busy state.
                  : ReportCard(key: ValueKey(list[i].id), report: list[i]),
            ),
    );
  }
}
