// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Space performance and capacity: message retention, the per-channel canvas
/// object cap, and the screen-share resolution ceiling.
///
/// Split out of `analytics_screen.dart`, which used to hold all three
/// alongside the usage-analytics toggle and charts even though none of the
/// three has anything to do with recording or reading usage: they are
/// capacity dials an admin reaches for regardless of whether analytics
/// recording is on, and analytics now holds only the toggle and the charts.
///
/// Requires MANAGE_SERVER, the same bit `/space/settings`, the Emoji screen,
/// and Analytics all require.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/admin_providers.dart';
import '../../providers/providers.dart';
import '../../routing/routes.dart';
import '../../widgets/attachment_format.dart' show formatByteSize;
import '../../widgets/optimistic_setting_state.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/success_flash.dart';
import '../settings_screen_scaffold.dart';
import 'canvas_cap_section.dart';
import 'screen_share_cap_section.dart';
import '../../action_labels.dart';

class PerformanceScreen extends StatelessWidget {
  const PerformanceScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: ActionLabels.retentionAndLimits,
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: PerformancePane(),
  );
}

/// The three capacity controls, embeddable as a Space settings pane as well
/// as routed.
class PerformancePane extends StatelessWidget {
  const PerformancePane({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _RetentionSection(),
      SizedBox(height: AppSpacing.s16),
      CanvasCapSection(),
      SizedBox(height: AppSpacing.s16),
      ScreenShareCapSection(),
    ],
  );
}

const _dayMs = 24 * 60 * 60 * 1000;

/// Days a pruned message is kept before the sweep removes it; index-matched
/// to the segmented options below. `0` is keep forever, the default and
/// what every deployment keeps until an admin sets one.
const _retentionDayOptions = <(String, int)>[
  ('Never', 0),
  ('30 days', 30),
  ('90 days', 90),
  ('365 days', 365),
];

/// `YYYY-MM-DD`, local time - retention is a whole-day window, so a
/// time-of-day carries no information a fuller timestamp would otherwise add.
String _dateOnly(int epochMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final y = dt.year.toString().padLeft(4, '0');
  final mo = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '$y-$mo-$d';
}

/// What choosing [days] actually does, grounded in `message_retention.rs`'s
/// own doc: a prune is a soft delete that leaves message text in place (it is
/// small next to attachment bytes) and only reclaims attachments no longer
/// referenced, plus old sync-log rows past the same cutoff. [stats], when
/// analytics is on, grounds that in this space's own current totals rather
/// than leaving the claim abstract; when it is off there is no honest number
/// to show, so this says so instead of guessing.
String retentionConsequence(int days, api.AnalyticsStats? stats) {
  if (days <= 0) {
    return 'Nothing is pruned: messages and their attachments are kept '
        'indefinitely.';
  }
  final cutoff = _dateOnly(
    DateTime.now().millisecondsSinceEpoch - days * _dayMs,
  );
  final buffer = StringBuffer(
    'Prunes anything older than $cutoff, freeing mostly attachment storage.',
  );
  if (stats != null) {
    buffer.write(
      ' This space holds ${formatByteSize(stats.attachmentBytes)} across '
      '${stats.totalMessages} messages; only what predates the cutoff is '
      'freed.',
    );
  } else {
    buffer.write(
      " Turn on Space analytics to see this space's current totals.",
    );
  }
  return buffer.toString();
}

/// The message retention window: an operator disk-pressure control,
/// independent of the analytics toggle - it stays visible and usable whether
/// or not Space analytics recording is on.
class _RetentionSection extends ConsumerStatefulWidget {
  const _RetentionSection();

  @override
  ConsumerState<_RetentionSection> createState() => _RetentionSectionState();
}

class _RetentionSectionState extends ConsumerState<_RetentionSection>
    with
        GuardedActionState<_RetentionSection>,
        OptimisticSettingState<_RetentionSection, int> {
  Future<void> _setDays(int days) => saveOptimistic(
    days,
    whatFailed: 'change the message retention window',
    action: () => ref.read(apiProvider).setSpaceMessageRetentionDays(days),
    refresh: spaceRetentionProvider,
  );

  @override
  Widget build(BuildContext context) {
    final retention = ref.watch(spaceRetentionProvider);
    ref.listen(spaceRetentionProvider, (_, next) => retireOptimistic(next));
    final current = shown(retention.valueOrNull, 0);
    final selectedIndex = _retentionDayOptions.indexWhere(
      (o) => o.$2 == current,
    );
    final stats = ref.watch(spaceAnalyticsProvider).valueOrNull?.stats;

    return SettingsSectionCard(
      title: 'Message retention',
      description: 'How long messages are kept before they are deleted.',
      children: [
        AppSegmentedControl.inline(
          semanticLabel: 'Message retention window',
          options: [
            for (final option in _retentionDayOptions)
              AppSegmentedOption(label: option.$1, disabled: saving),
          ],
          selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
          onSegmentSelected: (i) => _setDays(_retentionDayOptions[i].$2),
        ),
        const SizedBox(height: AppSpacing.s12),
        AppCallout(
          tone: AppCalloutTone.info,
          child: Text(retentionConsequence(current, stats)),
        ),
        SuccessFlash(tick: successTick),
        if (actionError != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(message: actionError!, onDismiss: clearActionError),
        ],
      ],
    );
  }
}
