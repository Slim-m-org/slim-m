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

import '../../providers/admin_providers.dart';
import '../../providers/providers.dart';
import '../../routing/routes.dart';
import '../../widgets/attachment_format.dart' show formatByteSize;
import '../../widgets/confirm_dialog.dart';
import '../../widgets/optimistic_setting_state.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_segmented_block.dart';
import '../settings_screen_scaffold.dart';
import 'attachment_limit_section.dart';
import 'canvas_cap_section.dart';
import 'noise_suppression_default_section.dart';
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

/// The capacity controls and the call defaults, embeddable as a Space settings pane as well
/// as routed.
class PerformancePane extends StatelessWidget {
  const PerformancePane({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _RetentionSection(),
      CanvasCapSection(),
      ScreenShareCapSection(),
      AttachmentLimitSection(),
      NoiseSuppressionDefaultSection(),
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

/// Whether moving the window from [from] to [to] starts pruning, or prunes
/// further back than before; loosening it deletes nothing.
bool retentionDeletesHistory({required int from, required int to}) =>
    to > 0 && (from <= 0 || to < from);

/// The date before which a [days]-day window prunes.
String retentionCutoff(int days) =>
    _dateOnly(DateTime.now().millisecondsSinceEpoch - days * _dayMs);

/// The confirmation's body: how many messages go, and when. The sweep runs
/// every few hours, so nothing is deleted the instant this is saved.
String retentionConfirmMessage(int days, int? count) {
  final when =
      'within the next few hours, for everyone. This cannot be undone.';
  if (count == null) {
    return 'Messages and attachments from before ${retentionCutoff(days)} '
        'are deleted $when';
  }
  if (count == 0) {
    return 'No messages are older than $days days yet. From now on, messages '
        'are deleted once they are $days days old.';
  }
  final noun = count == 1 ? 'message' : 'messages';
  return '$count $noun from before ${retentionCutoff(days)}, and their '
      'attachments, will be deleted $when';
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
  Future<void> _setDays(int days, {required int current}) async {
    if (retentionDeletesHistory(from: current, to: days)) {
      final count = await _previewCount(days);
      if (!mounted) return;
      final confirmed = await confirmDangerousAction(
        context,
        title: 'Delete messages older than $days days?',
        message: retentionConfirmMessage(days, count),
        confirmLabel: count == 0 ? 'Set to $days days' : 'Delete old messages',
      );
      if (!confirmed || !mounted) return;
    }
    await saveOptimistic(
      days,
      whatFailed: 'change the message retention window',
      action: () => ref.read(apiProvider).setSpaceMessageRetentionDays(days),
      refresh: spaceRetentionProvider,
    );
  }

  /// Null when the count could not be read; the dialog still warns, without it.
  Future<int?> _previewCount(int days) async {
    try {
      return await ref.read(apiProvider).previewSpaceMessageRetention(days);
    } on api.ApiException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final retention = ref.watch(spaceRetentionProvider);
    ref.listen(spaceRetentionProvider, (_, next) => retireOptimistic(next));
    final current = shown(retention.valueOrNull, 0);
    final selectedIndex = _retentionDayOptions.indexWhere(
      (o) => o.$2 == current,
    );
    final stats = ref.watch(spaceAnalyticsProvider).valueOrNull?.stats;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          flush: true,
          title: 'Message retention',
          description: 'How long messages are kept before they are deleted.',
          children: [
            SettingsSegmentedBlock(
              semanticLabel: 'Message retention window',
              labels: [for (final option in _retentionDayOptions) option.$1],
              selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
              disabled: saving,
              onSelected: (i) =>
                  _setDays(_retentionDayOptions[i].$2, current: current),
            ),
            SettingsSubRow(label: retentionConsequence(current, stats)),
          ],
        ),
        SettingsSaveFeedback(
          tick: successTick,
          error: actionError,
          onDismissError: clearActionError,
        ),
      ],
    );
  }
}
