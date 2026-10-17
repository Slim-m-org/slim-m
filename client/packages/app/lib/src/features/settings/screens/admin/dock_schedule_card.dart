// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Runs on its own": what an installed module does on a timer and the one
/// channel it posts in (docs/decisions/0023-mediated-host-capabilities.md,
/// the `schedule` amendment).
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_info_line.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_select_row.dart';

const _noChannel = '';

/// "every 15 minutes", "every hour", "every 2 days".
String dockEveryWords(int minutes) {
  String unit(int n, String name) =>
      n == 1 ? 'every $name' : 'every $n ${name}s';
  if (minutes % 10080 == 0) return unit(minutes ~/ 10080, 'week');
  if (minutes % 1440 == 0) return unit(minutes ~/ 1440, 'day');
  if (minutes % 60 == 0) return unit(minutes ~/ 60, 'hour');
  return unit(minutes, 'minute');
}

class DockScheduleCard extends StatelessWidget {
  const DockScheduleCard({
    super.key,
    required this.schedules,
    required this.channels,
    required this.channelId,
    required this.onChannel,
    this.enabled = true,
  });

  final List<api.DockSchedule> schedules;

  /// Text channels the admin can pick from.
  final List<api.Channel> channels;

  /// The chosen channel, or null for none.
  final String? channelId;
  final ValueChanged<String?> onChannel;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final choices = [
      const SettingsChoice(value: _noChannel, label: 'None'),
      for (final c in channels)
        SettingsChoice(value: c.id, label: '#${c.name}'),
    ];
    final chosen = channels.any((c) => c.id == channelId)
        ? channelId!
        : _noChannel;
    return SettingsSectionCard(
      title: 'Schedule',
      children: [
        for (final s in schedules)
          SettingsDetailRow(
            icon: AppIcons.clock,
            title: 'Runs ${s.command} ${dockEveryWords(s.everyMinutes)}',
          ),
        IgnorePointer(
          ignoring: !enabled,
          child: SettingsSelectRow<String>(
            label: 'Posts in',
            value: chosen,
            choices: choices,
            onChanged: (v) => onChannel(v == _noChannel ? null : v),
          ),
        ),
        if (chosen == _noChannel)
          const SettingsInfoLine(
            'It will not run on its own until you pick a channel.',
            warn: true,
          ),
      ],
    );
  }
}
