// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The operator alert banner: who sees it, the live refetch, dismissal, the mute, and the PNGs
/// for looking at it under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/admin_alerts/widgets/admin_alert_banner_host.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/mid_flight_capture.dart';
import '../../ui_snapshot_support.dart';
import 'alerts_harness.dart';

const _banner = Key('admin-alert-banner');

Future<GoRouter> _pump(
  WidgetTester tester,
  FakeServer server, {
  int permissions = manageServerBit,
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = server.container(permissions: permissions);
  addTearDown(container.dispose);
  addTearDown(server.events.close);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const AdminAlertBannerHost(
          child: Scaffold(body: Center(child: Text('shell'))),
        ),
      ),
      GoRoute(
        path: Routes.adminStorage,
        builder: (context, state) => const Text('storage pane'),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            brightness,
            brightness == Brightness.light ? AppTokens.light : AppTokens.dark,
          ),
          routerConfig: router,
        ),
      ),
    ),
  );
  await _settle(tester);
  return router;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('a member never asks for the alerts and sees no banner', (
    tester,
  ) async {
    final server = FakeServer()..alerts = [alertJson()];

    await _pump(tester, server, permissions: 0);

    expect(find.byKey(_banner), findsNothing);
    expect(server.requests, isNot(contains('GET /space/alerts')));
  });

  testWidgets('an admin with an open alert sees it and View opens Storage', (
    tester,
  ) async {
    final server = FakeServer()..alerts = [alertJson()];
    final router = await _pump(tester, server);

    expect(find.byKey(_banner), findsOneWidget);
    expect(find.textContaining('Only 90 MB are free'), findsOneWidget);

    await tester.tap(find.byKey(const Key('admin-alert-view')));
    await _settle(tester);

    expect(router.state.uri.path, Routes.adminStorage);
  });

  testWidgets('a recovered alert shows no banner', (tester) async {
    final server = FakeServer()
      ..alerts = [alertJson(resolvedAt: 1700000100000)];

    await _pump(tester, server);

    expect(find.byKey(_banner), findsNothing);
  });

  testWidgets('a muted admin sees no banner even with an open alert', (
    tester,
  ) async {
    final server = FakeServer()
      ..alerts = [alertJson()]
      ..muted = true;

    await _pump(tester, server);

    expect(find.byKey(_banner), findsNothing);
  });

  testWidgets('the live event refetches and the banner appears', (
    tester,
  ) async {
    final server = FakeServer();
    await _pump(tester, server);
    expect(find.byKey(_banner), findsNothing);

    server.alerts = [
      alertJson(kind: 'backup', detail: 'The nightly backup failed.'),
    ];
    server.events.add(const api.AdminAlertsChanged());
    await _settle(tester);

    expect(find.textContaining('The nightly backup failed.'), findsOneWidget);
  });

  testWidgets('dismissing hides it until the alert opens again', (
    tester,
  ) async {
    final server = FakeServer()..alerts = [alertJson()];
    await _pump(tester, server);

    await tester.tap(find.byKey(const Key('admin-alert-dismiss')));
    await _settle(tester);
    expect(find.byKey(_banner), findsNothing);

    server.events.add(const api.AdminAlertsChanged());
    await _settle(tester);
    expect(
      find.byKey(_banner),
      findsNothing,
      reason: 'the same opening stays hidden',
    );

    server.alerts = [alertJson(raisedAt: 1700009999999)];
    server.events.add(const api.AdminAlertsChanged());
    await _settle(tester);
    expect(find.byKey(_banner), findsOneWidget);
  });

  testWidgets('several open alerts read as the newest and a count', (
    tester,
  ) async {
    final server = FakeServer()
      ..alerts = [
        alertJson(kind: 'backup', detail: 'The nightly backup failed.'),
        alertJson(),
      ];

    await _pump(tester, server);

    expect(
      find.textContaining('The nightly backup failed. (+1 more)'),
      findsOneWidget,
    );
  });

  const viewports = {'phone': Size(390, 844), 'desktop': Size(1440, 900)};
  for (final viewport in viewports.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('banner at ${viewport.key} ${brightness.name} fits', (
        tester,
      ) async {
        final server = FakeServer()
          ..alerts = [
            alertJson(
              kind: 'backup',
              detail:
                  'The nightly backup failed: drill: integrity_check failed.',
            ),
            alertJson(),
          ];
        await _pump(
          tester,
          server,
          size: viewport.value,
          brightness: brightness,
        );

        final name = 'admin-alert-banner-${viewport.key}-${brightness.name}';
        await expectSettled(tester, name);
        expect(tester.takeException(), isNull);
        await writeSnapshot(tester, name);
      });
    }
  }
}
