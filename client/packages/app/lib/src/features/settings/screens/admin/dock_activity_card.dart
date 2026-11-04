// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Activity": how an installed module's commands have run lately. A
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

/// "1.2M", "340k", "12": a fuel count a person can read at a glance.
String dockFuel(int fuel) {
  if (fuel >= 1000000) {
    return '${(fuel / 1000000).toStringAsFixed(fuel < 10000000 ? 1 : 0)}M';
  }
  if (fuel >= 1000) {
    return '${(fuel / 1000).toStringAsFixed(fuel < 10000 ? 1 : 0)}k';
  }
  return '$fuel';
}

/// "Fuel: 1.2M last run, 3.4M most, of 50M.", or nothing when no run has been read.
String? dockFuelLine(api.DockRunStat stat, int limit) {
  final last = stat.lastFuelUsed;
  if (last == null && stat.maxFuelUsed == 0) return null;
  final parts = [
    if (last != null) '${dockFuel(last)} last run',
    '${dockFuel(stat.maxFuelUsed)} most',
  ].join(', ');
  return limit > 0 ? 'Fuel: $parts, of ${dockFuel(limit)}.' : 'Fuel: $parts.';
}

class DockActivityCard extends StatelessWidget {
  const DockActivityCard({
    super.key,
    required this.stats,
    this.fuelLimit = 0,
    this.now,
  });

  /// The fuel one run may burn, which each command's fuel is shown against.
  final int fuelLimit;

  final List<api.DockRunStat> stats;

  /// The clock the ages are read against; tests pin it.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return SettingsSectionCard(
      title: 'Activity',
      children: [
        if (stats.isEmpty) const SettingsInfoLine('It has not run yet.'),
        for (final stat in stats)
          _StatRow(stat: stat, fuelLimit: fuelLimit, now: now),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.stat, required this.fuelLimit, this.now});

  final api.DockRunStat stat;
  final int fuelLimit;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final failingSince = stat.failingSince;
    final ran = formatRelativeAgeMs(stat.lastRunAt, now: now);
    final runs = stat.runCount == 1 ? '1 run' : '${stat.runCount} runs';
    final fuel = dockFuelLine(stat, fuelLimit);
    final detail = failingSince == null
        ? 'Last ran $ran. $runs, ${stat.failureCount} failed.'
              '${fuel == null ? '' : ' $fuel'}'
        : 'Failing since ${formatRelativeAgeMs(failingSince, now: now)}'
              '${stat.lastError == null ? '' : ': ${stat.lastError}'}'
              '${fuel == null ? '' : ' $fuel'}';
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
