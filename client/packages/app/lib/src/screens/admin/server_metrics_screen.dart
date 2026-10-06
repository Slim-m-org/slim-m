// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Live server request timing and resource occupancy: `GET /metrics`.
/// Requires MANAGE_SERVER, the same bit `/space/settings`, Emoji,
/// Performance, Analytics, and Storage all require.
///
/// Built for finding a bottleneck, not for a trend line: unlike
/// `AnalyticsPane`'s memory samples, nothing here is a time series - it is
/// the server's own in-process counters and histograms as they stand right
/// now, re-fetched on every visit. See `route_timing.rs` on the server for
/// why latency has to be recorded continuously rather than sampled lazily
/// the way the analytics memory trend is.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/admin_providers.dart';
import '../../routing/routes.dart';
import '../../widgets/analytics_bar_chart.dart';
import '../../widgets/attachment_view.dart' show formatByteSize;
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import 'admin_stat_tile.dart';
import 'server_metrics_routes_card.dart';

class ServerMetricsScreen extends StatelessWidget {
  const ServerMetricsScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Server metrics',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: ServerMetricsPane(),
  );
}

/// The read-only metrics view, embeddable as a Space settings pane as well
/// as routed.
class ServerMetricsPane extends ConsumerWidget {
  const ServerMetricsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metrics = ref.watch(serverMetricsProvider);
    return AppAsyncView<api.ServerMetrics>(
      value: AppAsyncState(data: metrics.valueOrNull, error: metrics.error),
      center: false,
      errorMessage: 'Could not load server metrics.',
      onRetry: () => ref.invalidate(serverMetricsProvider),
      data: (context, value) => _MetricsView(metrics: value),
    );
  }
}

class _MetricsView extends StatelessWidget {
  const _MetricsView({required this.metrics});

  final api.ServerMetrics metrics;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _SystemCard(metrics: metrics),
      const SizedBox(height: AppSpacing.s16),
      _RequestVolumeCard(requestsByClass: metrics.requestsByClass),
      const SizedBox(height: AppSpacing.s16),
      SlowestRoutesCard(routes: metrics.routes),
    ],
  );
}

/// Resident memory, open WebSocket connections, and SQLite pool occupancy -
/// the process-wide numbers a bottleneck search starts from before drilling
/// into any one route.
class _SystemCard extends StatelessWidget {
  const _SystemCard({required this.metrics});

  final api.ServerMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final pool = metrics.pool;
    return SettingsSectionCard(
      title: 'System',
      children: [
        Wrap(
          spacing: AppSpacing.s12,
          runSpacing: AppSpacing.s12,
          children: [
            AdminStatTile(
              label: 'Resident memory',
              value: metrics.residentMemoryBytes == null
                  ? 'unknown'
                  : formatByteSize(metrics.residentMemoryBytes!.round()),
            ),
            AdminStatTile(
              label: 'WebSocket connections',
              value: '${metrics.webSocketConnections}',
            ),
            AdminStatTile(
              label: 'DB pool in use',
              value: pool == null ? 'unknown' : '${pool.inUse} / ${pool.max}',
              warn: pool != null && pool.max > 0 && pool.inUse >= pool.max,
            ),
          ],
        ),
      ],
    );
  }
}

/// Requests admitted and refused per rate-limit class - the closest thing
/// the server has to request volume by kind of traffic; see
/// `http/metrics.rs`'s own doc for why it is not per-route.
class _RequestVolumeCard extends StatelessWidget {
  const _RequestVolumeCard({required this.requestsByClass});

  final List<api.RequestClassCount> requestsByClass;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (requestsByClass.isEmpty) {
      return SettingsSectionCard(
        title: 'Request volume by class',
        children: [
          Text(
            'No requests recorded since this server process started.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      );
    }
    final summaryLabel = requestsByClass
        .map(
          (c) => '${c.className}: ${c.admitted} admitted, ${c.refused} refused',
        )
        .join(', ');
    return SettingsSectionCard(
      title: 'Request volume by class',
      children: [
        AnalyticsBarChart(
          values: requestsByClass.map((c) => c.admitted.toDouble()).toList(),
          semanticsLabel: 'Requests admitted per class: $summaryLabel',
        ),
        const SizedBox(height: AppSpacing.s8),
        for (final entry in requestsByClass) _RequestClassRow(entry: entry),
      ],
    );
  }
}

class _RequestClassRow extends StatelessWidget {
  const _RequestClassRow({required this.entry});

  final api.RequestClassCount entry;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              entry.className,
              style: AppText.body.copyWith(color: tokens.textPrimary),
            ),
          ),
          Text(
            entry.refused == 0
                ? '${entry.admitted} admitted'
                : '${entry.admitted} admitted, ${entry.refused} refused',
            style: AppText.caption.copyWith(
              color: entry.refused == 0
                  ? tokens.textSecondary
                  : tokens.dangerText,
            ),
          ),
        ],
      ),
    );
  }
}
