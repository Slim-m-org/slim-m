// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Why the host turned a module off, and how its pushed events and scheduled
/// runs are going, so a tripped breaker is explained instead of a switch that
/// quietly sits off.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

/// Whether [installed] has anything to report: a reason, a streak or drops.
bool dockHasHealthNews(api.InstalledDockModule? installed) =>
    installed != null &&
    ((installed.disabledReason != null && !installed.enabled) ||
        installed.consecutiveFailures > 0 ||
        installed.eventsDropped > 0 ||
        installed.queueDepth > 0);

/// A banner, not a card: pinned above the module's tabs, so a tripped
/// breaker is seen whichever tab is open.
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

  List<String> _lines() => [
    if (installed.consecutiveFailures > 0)
      installed.consecutiveFailures == 1
          ? '1 run failed in a row.'
          : '${installed.consecutiveFailures} runs failed in a row.',
    if (installed.queueDepth > 0)
      installed.queueDepth == 1
          ? '1 event is waiting for it.'
          : '${installed.queueDepth} events are waiting for it.',
    if (installed.eventsDropped > 0)
      installed.eventsDropped == 1
          ? '1 event was dropped because it fell behind.'
          : '${installed.eventsDropped} events were dropped because it '
                'fell behind.',
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final reason = installed.disabledReason;
    final tripped = reason != null && !installed.enabled;
    final style = AppText.caption.copyWith(color: tokens.textPrimary);
    return AppCallout(
      tone: tripped ? AppCalloutTone.warn : AppCalloutTone.info,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tripped) ...[
            Text(
              'Turned off',
              style: style.copyWith(fontWeight: AppWeights.semi),
            ),
            Text(reason, style: style),
          ],
          for (final line in _lines()) Text(line, style: style),
          if (tripped) ...[
            const SizedBox(height: AppSpacing.s8),
            AppButton(
              label: 'Turn on',
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.sm,
              disabled: !enabled,
              onPressed: onTurnOn,
            ),
          ],
        ],
      ),
    );
  }
}
