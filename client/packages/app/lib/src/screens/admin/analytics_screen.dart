// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Space usage analytics: `GET`/`PATCH /space/analytics`. Requires
/// MANAGE_SERVER, the same bit `/space/settings` and the Emoji screen use.
///
/// Off by default on every deployment; see
/// `docs/decisions/0008-space-analytics.md`. The toggle is the whole
/// feature's on switch, and nothing below it is computed while it reads
/// off, including the counts this file derives on read rather than
/// records: the point is that the feature does not run at all until asked
/// for, not only that a background job is paused.
///
/// The toggle's own presentation depends on that same on/off value: off,
/// the full explanation sits beside it because deciding whether to turn
/// this on is the one moment that explanation earns its space, alongside a
/// ghost preview of what turning it on reveals ([AnalyticsGhostPreview]).
/// On, the row collapses to a label and a switch - a permanent paragraph
/// on a screen opened to read numbers is not decoration, it is a tax - and
/// the explanation stays reachable behind an info affordance rather than
/// gone.
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
import '../../widgets/success_flash.dart';
import '../settings_screen_scaffold.dart';
import 'admin_stat_tile.dart';
import 'analytics_charts.dart';
import 'analytics_ghost.dart';
import 'analytics_toggle.dart';

class AnalyticsScreen extends StatelessWidget {
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Analytics',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: AnalyticsPane(),
  );
}

/// The toggle and stats themselves, embeddable as a Space settings pane as
/// well as routed.
class AnalyticsPane extends ConsumerStatefulWidget {
  const AnalyticsPane({super.key});

  @override
  ConsumerState<AnalyticsPane> createState() => _AnalyticsPaneState();
}

class _AnalyticsPaneState extends ConsumerState<AnalyticsPane>
    with
        GuardedActionState<AnalyticsPane>,
        OptimisticSettingState<AnalyticsPane, bool> {
  Future<void> _setEnabled(bool value) => saveOptimistic(
    value,
    whatFailed: value ? 'turn analytics on' : 'turn analytics off',
    action: () => ref.read(apiProvider).setSpaceAnalyticsEnabled(value),
    refresh: spaceAnalyticsProvider,
  );

  @override
  Widget build(BuildContext context) {
    final analytics = ref.watch(spaceAnalyticsProvider);
    ref.listen(spaceAnalyticsProvider, (_, next) => retireOptimistic(next));

    final enabled = shown(analytics.valueOrNull?.enabled, false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnalyticsToggleHeader(
          enabled: enabled,
          // With no answer yet there is nothing to flip, so "on" is never guessed.
          busy: saving || analytics.isLoading || !analytics.hasValue,
          onChanged: _setEnabled,
        ),
        SuccessFlash(tick: successTick),
        if (actionError != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(message: actionError!, onDismiss: clearActionError),
        ],
        const SizedBox(height: AppSpacing.s16),
        // With no stats held to keep on screen, the error stands alone rather than beside an off-state preview.
        if (analytics.hasError &&
            (!enabled || analytics.valueOrNull?.stats == null))
          AppErrorState(
            message: 'Could not load analytics.',
            onRetry: () => ref.invalidate(spaceAnalyticsProvider),
          )
        else if (!enabled)
          const AnalyticsGhostPreview()
        else
          AppAsyncView<api.SpaceAnalytics>(
            // A failed retry keeps the stats on screen; see AppAsyncView's own doc.
            value: AppAsyncState(
              data: analytics.valueOrNull,
              error: analytics.error,
            ),
            center: false,
            errorMessage: 'Could not load analytics.',
            onRetry: () => ref.invalidate(spaceAnalyticsProvider),
            data: (context, value) => value.stats == null
                ? const AnalyticsGhostPreview()
                : _StatsView(
                    stats: value.stats!,
                    memberStorage: value.memberStorage ?? const [],
                  ),
          ),
      ],
    );
  }
}

class _StatsView extends StatelessWidget {
  const _StatsView({required this.stats, required this.memberStorage});

  final api.AnalyticsStats stats;
  final List<api.MemberAttachmentUsage> memberStorage;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _StatTiles(stats: stats),
      const SizedBox(height: AppSpacing.s16),
      MessagesByDayCard(stats: stats),
      const SizedBox(height: AppSpacing.s16),
      ActiveHoursCard(stats: stats),
      const SizedBox(height: AppSpacing.s16),
      MemoryCard(stats: stats),
      const SizedBox(height: AppSpacing.s16),
      MemberStorageCard(usage: memberStorage),
    ],
  );
}

class _StatTiles extends StatelessWidget {
  const _StatTiles({required this.stats});

  final api.AnalyticsStats stats;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: AppSpacing.s12,
    runSpacing: AppSpacing.s12,
    children: [
      AdminStatTile(label: 'Total messages', value: '${stats.totalMessages}'),
      AdminStatTile(label: 'Members', value: '${stats.memberCount}'),
      AdminStatTile(label: 'Channels', value: '${stats.channelCount}'),
      AdminStatTile(
        label: 'Attachments stored',
        value: formatByteSize(stats.attachmentBytes),
      ),
    ],
  );
}
