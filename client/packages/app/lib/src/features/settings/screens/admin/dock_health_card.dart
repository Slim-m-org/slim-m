// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Why the host turned a module off, and how its pushed events and scheduled
/// runs are going, so a tripped breaker is explained instead of a switch that
/// quietly sits off.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_info_line.dart';
import '../../widgets/settings_section_header.dart';

/// Whether [installed] has anything to report: a reason, a streak or drops.
bool dockHasHealthNews(api.InstalledDockModule? installed) =>
    installed != null &&
    ((installed.disabledReason != null && !installed.enabled) ||
        installed.consecutiveFailures > 0 ||
        installed.eventsDropped > 0);

class DockHealthCard extends StatelessWidget {
  const DockHealthCard({
    super.key,
    required this.installed,
    required this.onTurnOn,
    this.enabled = true,
  });

  final api.InstalledDockModule installed;
  final VoidCallback onTurnOn;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final reason = installed.disabledReason;
    final tripped = reason != null && !installed.enabled;
    return SettingsSectionCard(
      title: tripped ? 'Turned off' : 'Health',
      children: [
        if (tripped) ...[
          SettingsDetailRow(
            icon: AppIcons.warning,
            title: 'The host turned it off',
            detail: reason,
          ),
          SettingsActionRow(
            message: 'Turn it on once the cause is fixed.',
            action: AppButton(
              label: 'Turn on',
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.sm,
              disabled: !enabled,
              onPressed: onTurnOn,
            ),
          ),
        ],
        if (installed.consecutiveFailures > 0)
          SettingsInfoLine(
            installed.consecutiveFailures == 1
                ? '1 run failed in a row.'
                : '${installed.consecutiveFailures} runs failed in a row.',
          ),
        if (installed.eventsDropped > 0)
          SettingsInfoLine(
            installed.eventsDropped == 1
                ? '1 event was dropped because it fell behind.'
                : '${installed.eventsDropped} events were dropped because it '
                      'fell behind.',
          ),
      ],
    );
  }
}
