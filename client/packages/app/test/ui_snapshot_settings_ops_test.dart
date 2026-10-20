// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space settings Operations panes, populated, beside the settings nav at
/// desktop width and as the routed screen at phone width, so they are looked
/// at next to a personal pane.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/action_labels.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';

import 'ui_snapshot_support.dart';
import 'support/fake_api.dart';

const _storage = {
  'database_bytes': 52428800,
  'database_reclaimable_bytes': 3145728,
  'attachment_bytes': 734003200,
  'top_channels': [
    {'channel_id': 'c1', 'name': 'screenshots', 'attachment_bytes': 419430400},
    {'channel_id': 'c2', 'name': 'general', 'attachment_bytes': 209715200},
    {'channel_id': 'c3', 'name': 'memes', 'attachment_bytes': 104857600},
  ],
  'sweeps': [
    {'name': 'token', 'last_run_at': 1000, 'last_reclaimed': 3},
    {'name': 'attachments', 'last_run_at': 1000, 'last_reclaimed': 0},
  ],
};

const _metrics = api.ServerMetrics(
  residentMemoryBytes: 94371840,
  webSocketConnections: 12,
  requestsByClass: [
    api.RequestClassCount(className: 'read', admitted: 5120, refused: 0),
    api.RequestClassCount(className: 'write', admitted: 840, refused: 6),
    api.RequestClassCount(className: 'upload', admitted: 31, refused: 0),
  ],
  pool: api.DbPoolStats(max: 8, size: 8, inUse: 3),
  routes: [
    api.RouteMetric(
      method: 'GET',
      route: '/channels/{id}/messages',
      count: 4210,
      sumSeconds: 126.3,
      p95Seconds: 0.082,
    ),
    api.RouteMetric(
      method: 'POST',
      route: '/channels/{id}/messages',
      count: 640,
      sumSeconds: 30.7,
      p95Seconds: 0.21,
    ),
  ],
);

List<Override> _overrides() => [
  mockApiOverride((request) async {
    final body = switch (request.url.path) {
      '/space/analytics' => fixtureAnalyticsEnabled,
      '/space/retention' => const {'retention_days': 90},
      '/space/canvas-cap' => const {'object_cap': 20000},
      '/space/screen-share' => const {'max_height': 1440},
      '/space/attachment-limit' => const {
        'max_bytes': 104857600,
        'server_max_bytes': 1073741824,
      },
      '/space/storage' => _storage,
      _ => null,
    };
    if (body == null) return fixtureResponse(request);
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  }),
  serverMetricsProvider.overrideWith((ref) async => _metrics),
];

const _panes = <({String id, String label, String route})>[
  (
    id: 'performance',
    label: ActionLabels.retentionAndLimits,
    route: '/settings/performance',
  ),
  (id: 'analytics', label: 'Analytics', route: '/settings/analytics'),
  (id: 'storage', label: 'Storage', route: '/settings/storage'),
  (
    id: 'server-metrics',
    label: 'Server metrics',
    route: '/settings/server-metrics',
  ),
];

void main() {
  setUpAll(loadRealFonts);

  for (final pane in _panes) {
    testWidgets('space ops ${pane.id} at desktop (dark)', (tester) async {
      await renderSurface(
        tester,
        '/settings/space',
        'desktop',
        'dark',
        'space-ops-${pane.id}-desktop-dark',
        overrides: _overrides(),
        settleNestedResolve: true,
        afterSettle: (t) async {
          // The nav list outgrew the desktop frame, so a lower row is built lazily.
          if (find.text(pane.label).evaluate().isEmpty) {
            await t.drag(find.text('Reports').first, const Offset(0, -600));
            await t.pump();
          }
          await t.tap(find.text(pane.label).first);
          await t.pump();
          await t.pump(const Duration(milliseconds: 350));
        },
      );
    });

    testWidgets('space ops ${pane.id} at phone-portrait (dark)', (
      tester,
    ) async {
      await renderSurface(
        tester,
        pane.route,
        'phone-portrait',
        'dark',
        'space-ops-${pane.id}-phone-portrait-dark',
        overrides: _overrides(),
      );
    });
  }
}
