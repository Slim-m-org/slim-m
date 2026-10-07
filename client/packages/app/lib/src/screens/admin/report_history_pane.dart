// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The History tab beside the open-reports queue: `GET /reports/history`'s
/// merged feed of resolved reports and `moderation_audit_log` entries -
/// docs/decisions/0015-moderation-audit-log.md's audit trail, finally
/// reachable from the app (MOD4). Requires MANAGE_MESSAGES, the same bit
/// `reports_screen.dart`'s open queue already requires and enforces the same
/// way: there is no separate client-side gate, so a non-holder reaching this
/// pane by deep link sees the server's 403 rendered as an error rather than
/// any moderation content.
///
/// A plain `ListView.separated`, matching the open queue's own idiom and
/// never eager: the audit log grows without bound, and building every row up
/// front is the exact mistake fixed twice elsewhere this week (the
/// pins/threads sheets, and the emoji catalog, whose eager build fired
/// hundreds of concurrent image fetches).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/moderation_history_controller.dart';
import '../../providers/user_profiles.dart';
import 'report_history_row.dart';
import 'reports_load_more_row.dart';

/// [resolveAuthorProfiles] is called here for the whole page already on
/// screen, the same shape `pinned_messages_sheet.dart` uses, rather than per
/// row: it skips ids already known, so a rebuild that named no new id costs
/// nothing, and one batched call never fires the pile of concurrent fetches
/// a per-row request would.
class ReportHistoryPane extends ConsumerWidget {
  const ReportHistoryPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(moderationHistoryControllerProvider);
    final controller = ref.read(moderationHistoryControllerProvider.notifier);
    final items = history.items;

    // Watched so a cleared or evicted profile re-runs the call below.
    ref.watch(batchProfilesControllerProvider);
    // See this pane's own class doc for why this call sits here.
    resolveAuthorProfiles(ref, items.expand(_namedIds));

    return AppAsyncView<List<api.ModerationHistoryItem>>(
      value: AppAsyncState(
        data: history.loading && items.isEmpty ? null : items,
        error: items.isEmpty ? history.error : null,
      ),
      errorMessage: 'Could not load the moderation history.',
      onRetry: controller.refresh,
      isEmpty: (list) => list.isEmpty,
      emptyMessage: 'Nothing has happened here yet.',
      data: (context, list) => ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.s16),
        // One trailing row when the last page came back full; see the controller.
        itemCount: history.more || history.error != null
            ? list.length + 1
            : list.length,
        separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.s12),
        itemBuilder: (context, i) => i == list.length
            ? ReportsLoadMoreRow(
                loading: history.loading,
                error: history.error,
                failureMessage: 'Could not load more history.',
                onTap: controller.loadMore,
              )
            : ReportHistoryRow(
                key: ValueKey('${list[i].cursorKind}:${list[i].id}'),
                item: list[i],
              ),
      ),
    );
  }
}

/// The ids [ReportHistoryRow] needs a name for, so [ReportHistoryPane] can
/// resolve a page's worth in one call rather than one per row: the actor for
/// an audit entry, the resolving moderator for a report, and whichever of
/// author/subject that report actually names - see `ReportHistoryRow`'s own
/// doc for why that split follows `ReportCard`'s.
Iterable<String> _namedIds(api.ModerationHistoryItem item) => switch (item) {
  api.AuditLogHistoryEntry(:final actorId, :final subjectId) => [
    if (actorId != null) actorId,
    subjectId,
  ],
  api.ResolvedReportHistoryEntry(
    :final resolvedBy,
    :final subjectKind,
    :final subjectId,
    :final subjectAuthorId,
  ) =>
    [
      if (resolvedBy != null) resolvedBy,
      if (subjectKind == api.ReportSubject.user)
        subjectId
      else if (subjectAuthorId != null)
        subjectAuthorId,
    ],
};
