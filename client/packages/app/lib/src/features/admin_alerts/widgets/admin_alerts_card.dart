// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The operator alert list and the caller's mute, in Storage.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../format.dart';
import '../../settings/widgets/settings_detail_row.dart';
import '../../settings/widgets/settings_empty.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../../settings/widgets/settings_toggle_row.dart';
import '../providers/admin_alerts.dart';

class AdminAlertsCard extends ConsumerWidget {
  const AdminAlertsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(adminAlertsProvider).valueOrNull;
    if (alerts == null) return const SizedBox.shrink();
    return SettingsSectionCard(
      title: 'Alerts',
      children: [
        if (alerts.alerts.isEmpty)
          const SettingsEmptyState(
            key: Key('admin-alerts-empty'),
            icon: AppIcons.check,
            title: 'Nothing needs attention.',
          ),
        for (final alert in alerts.alerts) _AlertRow(alert: alert),
        SettingsToggleRow(
          key: const Key('admin-alerts-mute'),
          label: 'Mute alerts',
          description: 'No pushes or banners for you.',
          semanticLabel: 'Mute server alerts',
          value: alerts.muted,
          onChanged: (muted) => setAdminAlertsMuted(ref, muted),
        ),
      ],
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.alert});

  final api.AdminAlert alert;

  @override
  Widget build(BuildContext context) => SettingsDetailRow(
    key: Key('admin-alert-${alert.kind}-${alert.subject}'),
    icon: alert.isOpen ? AppIcons.warning : AppIcons.check,
    title: adminAlertTitle(alert.kind),
    detail:
        '${alert.detail} ${formatRelativeAgeMs(alert.resolvedAt ?? alert.raisedAt)}',
    badge: alert.isOpen
        ? null
        : AppBadge(
            key: Key('admin-alert-recovered-${alert.kind}-${alert.subject}'),
            variant: AppBadgeVariant.tag,
            label: 'Recovered',
          ),
  );
}

/// A label for an alert kind; one this client does not know shows its raw name.
String adminAlertTitle(String kind) => switch (kind) {
  'livekit_unreachable' => 'Voice server',
  'disk_low' => 'Disk space',
  'sweep_failing' => 'Background job',
  'backup' => 'Backup',
  'module_breaker' => 'Module',
  'push_relay' => 'Push relay',
  _ => kind,
};
