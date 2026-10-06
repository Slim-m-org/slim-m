// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas object cap control on the Space performance screen: it shows
/// the current cap, patches a new one, and states the estimated memory
/// consequence of the chosen cap. Split from `performance_screen_test.dart`,
/// which is at its file-size ceiling; the two share the screen but not a
/// file.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/performance_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _containerFor(MockClient client) => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    apiProvider.overrideWith((ref) {
      final built = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: client,
      );
      ref.onDispose(built.close);
      return built;
    }),
  ],
);

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: const Scaffold(body: PerformanceScreen()),
  ),
);

http.Response _json(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('the canvas cap section shows the current cap and patches a new '
      'one', (tester) async {
    var objectCap = 20000;
    final patchedCaps = <int>[];
    final client = MockClient((request) async {
      if (request.url.path == '/space/retention') {
        return _json({'retention_days': 0});
      }
      if (request.url.path == '/space/canvas-cap') {
        if (request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          objectCap = body['object_cap'] as int;
          patchedCaps.add(objectCap);
        }
        return _json({'object_cap': objectCap});
      }
      return _json({'enabled': false});
    });
    final container = _containerFor(client);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.text('Canvas object cap'), findsOneWidget);

    // The section sits below the fold in the test viewport; scroll first.
    await tester.ensureVisible(find.text('5,000'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5,000'));
    await tester.pumpAndSettle();

    expect(patchedCaps, [5000]);
  });

  testWidgets('states the estimated memory consequence, grounded in the measured '
      'anchors, and updates it when the cap changes', (tester) async {
    var objectCap = 20000;
    final client = MockClient((request) async {
      if (request.url.path == '/space/retention') {
        return _json({'retention_days': 0});
      }
      if (request.url.path == '/space/canvas-cap') {
        if (request.method == 'PATCH') {
          objectCap = (jsonDecode(request.body) as Map)['object_cap'] as int;
        }
        return _json({'object_cap': objectCap});
      }
      return _json({'enabled': false});
    });
    final container = _containerFor(client);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    // The default cap (20,000) is a real measured anchor, not an extrapolation.
    expect(
      find.textContaining('36.2 MB'),
      findsOneWidget,
      reason: 'the 20,000 anchor is a real measurement, not a guess',
    );
    // The reverse of what this used to assert; see canvas_memory_estimate.dart.
    expect(
      find.textContaining('docs/'),
      findsNothing,
      reason: 'settings copy names no doc paths; the reasoning lives in code',
    );

    await tester.ensureVisible(find.text('50,000'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('50,000'));
    await tester.pumpAndSettle();

    // Past every measured anchor: the estimate must say so plainly.
    expect(find.textContaining('36.2 MB'), findsNothing);
    expect(
      find.textContaining('Past what was measured'),
      findsOneWidget,
      reason: 'an extrapolated estimate must still say it is one',
    );
  });

  AppSegmentedControl capControl(WidgetTester tester) =>
      tester.widget<AppSegmentedControl>(
        find.byWidgetPredicate(
          (w) =>
              w is AppSegmentedControl && w.semanticLabel == 'Canvas object cap',
        ),
      );

  testWidgets('an off-preset cap selects no preset and states the real '
      'number', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/space/retention') {
        return _json({'retention_days': 0});
      }
      if (request.url.path == '/space/canvas-cap') {
        return _json({'object_cap': 1000});
      }
      return _json({'enabled': false});
    });
    final container = _containerFor(client);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('5,000'));

    expect(capControl(tester).selectedIndex, -1);
    expect(find.textContaining('1,000 objects'), findsOneWidget);
  });

  testWidgets('a failed cap load shows a retryable error, not a default '
      'preset', (tester) async {
    var capCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/space/retention') {
        return _json({'retention_days': 0});
      }
      if (request.url.path == '/space/canvas-cap') {
        capCalls++;
        if (capCalls == 1) return http.Response('boom', 500);
        return _json({'object_cap': 10000});
      }
      return _json({'enabled': false});
    });
    final container = _containerFor(client);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.text('Could not load the canvas object cap.'), findsOneWidget);
    expect(find.text('20,000'), findsNothing);

    await tester.ensureVisible(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Could not load the canvas object cap.'), findsNothing);
    await tester.ensureVisible(find.text('10,000'));
    expect(capControl(tester).selectedIndex, 1);
  });
}
