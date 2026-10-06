// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space analytics screen: the toggle's two shapes (a full explanation
/// off, a collapsed row on), the off-state ghost preview, and that the
/// headline numbers are visible text rather than only pixels in a chart.
///
/// Retention, the canvas object cap and the screen-share resolution ceiling
/// used to live on this same screen and so used to be exercised here; they
/// moved to their own Space performance screen (`performance_screen_test.dart`
/// and its own two split-out section tests), which is why this file no
/// longer answers `/space/retention`, `/space/canvas-cap` or
/// `/space/screen-share`.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/analytics_ghost.dart';
import 'package:slimm_app/src/screens/admin/analytics_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _enabledBody = {
  'enabled': true,
  'stats': {
    'total_messages': 42,
    'member_count': 3,
    'channel_count': 2,
    'attachment_bytes': 2048,
    'messages_by_day': [
      {'date': '2026-08-01', 'count': 5},
      {'date': '2026-08-02', 'count': 9},
    ],
    'active_hours': [
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
      0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ],
    'memory_samples': [
      {'sampled_at': 1000, 'rss_bytes': 7000000},
    ],
  },
};

ProviderContainer _containerFor(MockClient client) {
  final container = ProviderContainer(
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
  return container;
}

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: const Scaffold(body: AnalyticsScreen()),
  ),
);

/// What the pane answers for GET, flipped by the test to make a fetch fail.
class _Server {
  bool enabled = false;
  bool failGets = false;
  final gets = <int>[];

  Future<http.Response> handle(http.Request request) async {
    if (request.method == 'PATCH') {
      enabled = (jsonDecode(request.body) as Map)['enabled'] as bool;
      return http.Response(
        jsonEncode({'enabled': enabled}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    gets.add(gets.length);
    if (failGets) return http.Response('boom', 500);
    return http.Response(
      jsonEncode(enabled ? _enabledBody : {'enabled': false}),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

Future<_Server> _open(WidgetTester tester, {bool failFirst = false}) async {
  final server = _Server()..failGets = failFirst;
  final container = _containerFor(MockClient(server.handle));
  addTearDown(container.dispose);
  await tester.pumpWidget(_app(container));
  await tester.pumpAndSettle();
  return server;
}

AppToggle _toggle(WidgetTester tester) =>
    tester.widget<AppToggle>(find.byType(AppToggle));

void main() {
  group('a failed first load', () {
    testWidgets('shows an error with Retry and no off-state preview', (
      tester,
    ) async {
      await _open(tester, failFirst: true);

      expect(find.text('Could not load analytics.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byType(AnalyticsGhostPreview), findsNothing);
    });

    testWidgets('leaves the toggle off limits until there is an answer', (
      tester,
    ) async {
      await _open(tester, failFirst: true);

      expect(_toggle(tester).onChanged, isNull);
    });

    testWidgets('Retry loads the pane once the server is back', (tester) async {
      final server = await _open(tester, failFirst: true);

      server.failGets = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Could not load analytics.'), findsNothing);
      expect(find.byType(AnalyticsGhostPreview), findsOneWidget);
      expect(_toggle(tester).onChanged, isNotNull);
    });
  });

  group('a failed refetch after a toggle the server accepted', () {
    testWidgets('turning on keeps the toggle on and says it could not load', (
      tester,
    ) async {
      final server = await _open(tester);
      server.failGets = true;

      await tester.tap(find.byType(AppToggle));
      await tester.pumpAndSettle();

      expect(_toggle(tester).value, isTrue);
      expect(find.text('Could not load analytics.'), findsOneWidget);
      expect(find.byType(AnalyticsGhostPreview), findsNothing);
    });

    testWidgets('turning off keeps the toggle off and says it could not load', (
      tester,
    ) async {
      final server = await _open(tester);
      await tester.tap(find.byType(AppToggle));
      await tester.pumpAndSettle();
      expect(_toggle(tester).value, isTrue);
      server.failGets = true;

      await tester.tap(find.byType(AppToggle));
      await tester.pumpAndSettle();

      expect(_toggle(tester).value, isFalse);
      expect(find.text('Could not load analytics.'), findsOneWidget);
    });
  });
}
