// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests that the activity panel reserves bottom padding for the floating dock.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_panel.dart';
import 'package:slimm_app/src/providers/dock_reservation.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container({double dockHeight = 0}) => ProviderContainer(
  overrides: [
    bottomDockReservationProvider.overrideWith((ref) => dockHeight),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    liveEventsProvider.overrideWithValue(const Stream.empty()),
    mockApiOverride((request) async {
      if (request.url.path == '/users') {
        return http.Response(
          jsonEncode([
            {
              'id': 'alice',
              'username': 'alice',
              'display_name': 'Alice',
              'created_at': 0,
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('[]', 200);
    }),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  testWidgets('activity list reserves bottom space for floating dock', (
    tester,
  ) async {
    const dockHeight = 72.0;
    final container = _container(dockHeight: dockHeight);
    addTearDown(container.dispose);

    final log = CanvasActivityLog(isBlocked: (_) => false)
      ..recordClearedLive('op-1');

    await _pump(
      tester,
      container,
      CanvasActivityPanel(
        activityLog: log,
        summary: '1 object',
        objectCount: 1,
      ),
    );
    await tester.pump();

    final listView = tester.widget<ListView>(find.byType(ListView));
    final insets = listView.padding as EdgeInsets;
    expect(insets.bottom, dockHeight + AppSpacing.s16);

    log.dispose();
  });
}
