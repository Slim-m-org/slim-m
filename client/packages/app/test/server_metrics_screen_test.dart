// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The server metrics pane's content: routes ordered slowest first with
/// unobserved ones last, latency units, the empty state, and a pool at its
/// ceiling in the danger colour.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/screens/admin/server_metrics_routes_card.dart';
import 'package:slimm_app/src/screens/admin/server_metrics_screen.dart';
import 'package:slimm_design_system/design_system.dart';

api.RouteMetric _route(String path, {double? p95, int count = 10}) =>
    api.RouteMetric(
      method: 'GET',
      route: path,
      count: count,
      sumSeconds: 0.2 * count,
      p95Seconds: p95,
    );

api.ServerMetrics _metrics({
  List<api.RouteMetric> routes = const [],
  api.DbPoolStats pool = const api.DbPoolStats(max: 8, size: 8, inUse: 2),
}) => api.ServerMetrics(
  residentMemoryBytes: 1048576,
  webSocketConnections: 3,
  requestsByClass: const [],
  pool: pool,
  routes: routes,
);

Future<void> _pump(WidgetTester tester, api.ServerMetrics metrics) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [serverMetricsProvider.overrideWith((ref) async => metrics)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: ServerMetricsPane()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  testWidgets('routes list slowest p95 first and unobserved routes last', (
    tester,
  ) async {
    await _pump(
      tester,
      _metrics(
        routes: [
          _route('/never', count: 0),
          _route('/fast', p95: 0.2),
          _route('/slow', p95: 1.5),
        ],
      ),
    );

    expect(_top(tester, 'GET /slow'), lessThan(_top(tester, 'GET /fast')));
    expect(_top(tester, 'GET /fast'), lessThan(_top(tester, 'GET /never')));
    expect(find.text('1.5 s'), findsOneWidget);
    expect(find.text('200 ms'), findsWidgets);
    expect(find.text('-'), findsOneWidget, reason: 'no p95 reads as a dash');
  });

  testWidgets('no recorded routes shows the empty state', (tester) async {
    await _pump(tester, _metrics());

    expect(
      find.descendant(
        of: find.byType(SlowestRoutesCard),
        matching: find.text(
          'No requests recorded since this server process started.',
        ),
      ),
      findsOneWidget,
    );
  });

  Color? poolColor(WidgetTester tester, String value) =>
      tester.widget<Text>(find.text(value)).style?.color;

  testWidgets('a pool at its ceiling is drawn in the danger colour', (
    tester,
  ) async {
    await _pump(
      tester,
      _metrics(pool: const api.DbPoolStats(max: 8, size: 8, inUse: 8)),
    );

    expect(poolColor(tester, '8 / 8'), AppTokens.light.dangerText);
  });

  testWidgets('a pool with headroom keeps the ordinary text colour', (
    tester,
  ) async {
    await _pump(
      tester,
      _metrics(pool: const api.DbPoolStats(max: 8, size: 8, inUse: 2)),
    );

    expect(poolColor(tester, '2 / 8'), AppTokens.light.textPrimary);
  });

  test('formatLatency uses milliseconds under a second and seconds above', () {
    expect(formatLatency(0.003), '3 ms');
    expect(formatLatency(0.042), '42 ms');
    expect(formatLatency(1.24), '1.2 s');
  });
}
