// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Activity": how an installed module's commands have run lately, and how
/// much of its stored-data allowance it is using, with a way to empty it. A
/// scheduled module that has stopped posting shows up here as failing, with
/// the error, instead of looking like one with nothing to say.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../format.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_info_line.dart';
import '../../widgets/settings_section_header.dart';

/// "3 KB", "12 bytes": the coarse size a stored-data line needs.
String dockBytes(int bytes) {
  if (bytes < 1024) return '$bytes bytes';
  final kib = bytes / 1024;
  return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
}

class DockActivityCard extends StatelessWidget {
  const DockActivityCard({
    super.key,
    required this.stats,
    required this.storage,
    required this.onClearStorage,
    this.keepsData = false,
    this.enabled = true,
    this.now,
  });

  final List<api.DockRunStat> stats;
  final api.DockStorage? storage;

  /// Whether the module is approved to store data at all.
  final bool keepsData;
  final VoidCallback onClearStorage;
  final bool enabled;

  /// The clock the ages are read against; tests pin it.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final storage = this.storage;
    return SettingsSectionCard(
      title: 'Activity',
      children: [
        if (stats.isEmpty) const SettingsInfoLine('It has not run yet.'),
        for (final stat in stats) _StatRow(stat: stat, now: now),
        if (keepsData && storage != null)
          SettingsDetailRow(
            icon: AppIcons.storage,
            title: 'Stored data',
            detail:
                '${storage.entries} of ${storage.maxEntries} entries, '
                '${dockBytes(storage.bytes)} of ${dockBytes(storage.maxBytes)}',
            trailing: AppButton(
              label: 'Clear',
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.sm,
              semanticLabel: 'Clear stored data',
              disabled: !enabled || storage.entries == 0,
              onPressed: onClearStorage,
            ),
          ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.stat, this.now});

  final api.DockRunStat stat;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final failingSince = stat.failingSince;
    final ran = formatRelativeAgeMs(stat.lastRunAt, now: now);
    final runs = stat.runCount == 1 ? '1 run' : '${stat.runCount} runs';
    final detail = failingSince == null
        ? 'Last ran $ran. $runs, ${stat.failureCount} failed.'
        : 'Failing since ${formatRelativeAgeMs(failingSince, now: now)}'
              '${stat.lastError == null ? '' : ': ${stat.lastError}'}';
    return SettingsDetailRow(
      icon: failingSince == null ? AppIcons.clock : AppIcons.warning,
      title: stat.command,
      detail: detail,
      badge: failingSince == null
          ? null
          : const AppBadge(variant: AppBadgeVariant.warn, label: 'Failing'),
    );
  }
}
