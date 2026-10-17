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

import '../../../../providers/admin_providers.dart';
import '../../../../routing/routes.dart';
import '../../../../widgets/analytics_bar_chart.dart';
import '../../../messages/widgets/attachment_format.dart' show formatByteSize;
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_meter_row.dart';
import '../../widgets/settings_refresh_button.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
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

class _MetricsView extends ConsumerWidget {
  const _MetricsView({required this.metrics});

  final api.ServerMetrics metrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _SystemCard(
        metrics: metrics,
        onRefresh: () => ref.invalidate(serverMetricsProvider),
      ),
      _RequestVolumeCard(requestsByClass: metrics.requestsByClass),
      SlowestRoutesCard(routes: metrics.routes),
    ],
  );
}

/// Resident memory, open WebSocket connections, and SQLite pool occupancy -
/// the process-wide numbers a bottleneck search starts from before drilling
/// into any one route.
class _SystemCard extends StatelessWidget {
  const _SystemCard({required this.metrics, required this.onRefresh});

  final api.ServerMetrics metrics;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final pool = metrics.pool;
    return SettingsSectionCard(
      title: 'System',
      trailing: SettingsRefreshButton(
        label: 'Refresh server metrics',
        onPressed: onRefresh,
      ),
      children: [
        SettingsMeterRow(
          label: 'Resident memory',
          value: metrics.residentMemoryBytes == null
              ? 'unknown'
              : formatByteSize(metrics.residentMemoryBytes!.round()),
        ),
        SettingsMeterRow(
          label: 'WebSocket connections',
          value: '${metrics.webSocketConnections}',
        ),
        if (pool == null)
          const SettingsMeterRow(label: 'DB pool in use', value: 'unknown')
        else
          SettingsMeterRow(
            label: 'DB pool in use',
            value: '${pool.inUse}',
            of: 'of ${pool.max}',
            fraction: meterFraction(pool.inUse, pool.max),
            warn: pool.max > 0 && pool.inUse >= pool.max,
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
    if (requestsByClass.isEmpty) {
      return const SettingsSectionCard(
        title: 'Request volume by class',
        children: [
          SettingsEmptyState(
            icon: AppIcons.requestLatency,
            title: 'No requests recorded since this server process started.',
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
        SettingsCardBlock(
          children: [
            AnalyticsBarChart(
              values: requestsByClass
                  .map((c) => c.admitted.toDouble())
                  .toList(),
              semanticsLabel: 'Requests admitted per class: $summaryLabel',
            ),
          ],
        ),
        for (final entry in requestsByClass)
          SettingsMeterRow(
            label: entry.className,
            value: entry.refused == 0
                ? '${entry.admitted} admitted'
                : '${entry.admitted} admitted, ${entry.refused} refused',
            warn: entry.refused > 0,
          ),
      ],
    );
  }
}
