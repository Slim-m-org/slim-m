// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every admin change to the space, newest first: `GET /space/audit-log`.
/// Requires MANAGE_SERVER, the same bit the pane is gated on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../members/providers/user_profiles.dart';
import '../../providers/admin_audit_log_controller.dart';
import '../../../../routing/routes.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import 'audit_log_row.dart';
import 'reports_load_more_row.dart';

class AuditLogScreen extends StatelessWidget {
  const AuditLogScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Audit log',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    scrollable: false,
    child: AuditLogPane(),
  );
}

/// The audit log, embeddable as a Space settings pane as well as routed.
class AuditLogPane extends ConsumerWidget {
  const AuditLogPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(adminAuditLogControllerProvider);
    final controller = ref.read(adminAuditLogControllerProvider.notifier);
    final items = log.items;

    // Watched so an evicted profile re-runs the call below.
    ref.watch(batchProfilesControllerProvider);
    resolveAuthorProfiles(ref, items.expand(_namedIds));

    return AppAsyncView<List<api.AdminChange>>(
      value: AppAsyncState(
        data: log.loading && items.isEmpty ? null : items,
        error: items.isEmpty ? log.error : null,
      ),
      errorMessage: 'Could not load the audit log.',
      onRetry: controller.refresh,
      data: (context, list) => ListView(
        children: [
          SettingsSectionCard(
            title: 'Audit log',
            description: 'Changes admins made to this space, newest first.',
            children: [
              if (list.isEmpty)
                const SettingsEmptyState(
                  icon: AppIcons.activityLog,
                  title: 'No changes recorded yet',
                )
              else
                for (final change in list)
                  AuditLogRow(key: ValueKey(change.id), change: change),
            ],
          ),
          if (list.isNotEmpty && (log.more || log.error != null))
            ReportsLoadMoreRow(
              loading: log.loading,
              error: log.error,
              failureMessage: 'Could not load more changes.',
              onTap: controller.loadMore,
            ),
        ],
      ),
    );
  }
}

Iterable<String> _namedIds(api.AdminChange change) => [
  if (change.actorId case final actor?) actor,
  if (change.action == 'role.assign' || change.action == 'role.unassign')
    ?change.targetId,
];
