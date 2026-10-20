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

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/screens/admin/analytics_ghost.dart';
import 'package:slimm_app/src/features/settings/screens/admin/analytics_screen.dart';
import 'package:slimm_app/src/features/settings/screens/admin/analytics_toggle.dart';
import 'package:slimm_app/src/widgets/analytics_bar_chart.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

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

void main() {
  testWidgets(
    'off by default: the full explanation and a ghost preview show, no '
    'stat is computed',
    (tester) async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({'enabled': false}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      expect(find.text('Record Space analytics'), findsOneWidget);
      expect(find.text(analyticsToggleDescription), findsOneWidget);
      expect(find.byType(AnalyticsGhostPreview), findsOneWidget);
      expect(find.textContaining('Total messages'), findsNothing);
      expect(find.byType(AnalyticsBarChart), findsNothing);
    },
  );

  testWidgets('turning it on sends enabled: true and the screen shows stats', (
    tester,
  ) async {
    var enabled = false;
    final patchedBodies = <Map<String, dynamic>>[];

    final client = MockClient((request) async {
      if (request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        patchedBodies.add(body);
        enabled = body['enabled'] as bool;
      }
      return http.Response(
        jsonEncode(enabled ? _enabledBody : {'enabled': false}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final container = _containerFor(client);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();

    expect(patchedBodies, [
      {'enabled': true},
    ]);
    expect(find.byType(AnalyticsGhostPreview), findsNothing);
    expect(find.text('Space analytics is on'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
  });

  testWidgets(
    'enabled collapses the toggle to a single row, with the explanation '
    'reachable but closed by default',
    (tester) async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(_enabledBody),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      // Collapsed: the label shows, the paragraph does not.
      expect(find.text('Space analytics is on'), findsOneWidget);
      expect(find.text(analyticsToggleDescription), findsNothing);

      // The info button reveals it in place.
      await tester.tap(find.byTooltip('What this records'));
      await tester.pumpAndSettle();
      expect(find.text(analyticsToggleDescription), findsOneWidget);

      // And hides it again on a second tap.
      await tester.tap(find.byTooltip('Hide what this records'));
      await tester.pumpAndSettle();
      expect(find.text(analyticsToggleDescription), findsNothing);
    },
  );

  testWidgets(
    'the toggle flips the instant it is tapped, ahead of the server',
    (tester) async {
      final gate = Completer<void>();
      var enabled = false;
      final client = MockClient((request) async {
        if (request.method == 'PATCH') {
          await gate.future;
          enabled = (jsonDecode(request.body) as Map)['enabled'] as bool;
          return http.Response(
            jsonEncode({'enabled': enabled}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(enabled ? _enabledBody : {'enabled': false}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();
      expect(tester.widget<AppToggle>(find.byType(AppToggle)).value, isFalse);

      await tester.tap(find.byType(AppToggle));
      await tester.pump();
      // The request has not answered yet, and the toggle already shows it.
      expect(tester.widget<AppToggle>(find.byType(AppToggle)).value, isTrue);

      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<AppToggle>(find.byType(AppToggle)).value, isTrue);
    },
  );

  testWidgets('a refused toggle reverts instead of lying', (tester) async {
    // Gated so the refusal cannot land inside the tap's own microtasks.
    final gate = Completer<void>();
    final client = MockClient((request) async {
      if (request.method == 'PATCH') {
        await gate.future;
        return http.Response('', 500);
      }
      return http.Response(
        jsonEncode({'enabled': false}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final container = _containerFor(client);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AppToggle));
    await tester.pump();
    expect(tester.widget<AppToggle>(find.byType(AppToggle)).value, isTrue);

    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<AppToggle>(find.byType(AppToggle)).value, isFalse);
    expect(find.textContaining('Could not'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('a successful write flashes a transient Saved', (tester) async {
    var enabled = false;
    final client = MockClient((request) async {
      if (request.method == 'PATCH') {
        enabled = (jsonDecode(request.body) as Map)['enabled'] as bool;
      }
      return http.Response(
        jsonEncode(enabled ? _enabledBody : {'enabled': false}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final container = _containerFor(client);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsNothing);

    await tester.tap(find.byType(AppToggle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Saved'), findsOneWidget);

    // The acknowledgement is transient: nothing lingers once it has played.
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets(
    'an enabled deployment shows the numbers as text, not only a chart',
    (tester) async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(_enabledBody),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      // The four stat tiles, as visible text.
      expect(find.text('42'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('2.0 KB'), findsOneWidget);

      // A screen reader gets the series as text, not only the chart's pixels.
      final daySemantics = tester.getSemantics(
        find.byType(AnalyticsBarChart).first,
      );
      expect(daySemantics.label, contains('2026-08-01: 5'));
      expect(daySemantics.label, contains('2026-08-02: 9'));
    },
  );

  testWidgets(
    'retrying after stats already loaded and the retry itself fails keeps '
    'the stats on screen instead of wiping them',
    (tester) async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        // First answer succeeds; the retry (second GET) fails.
        if (requests > 1) return http.Response('', 500);
        return http.Response(
          jsonEncode(_enabledBody),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();
      expect(find.text('42'), findsOneWidget);

      container.invalidate(spaceAnalyticsProvider);
      await tester.pumpAndSettle();

      expect(find.text('Could not load analytics.'), findsOneWidget);
      // The stats already on screen stay there rather than being replaced.
      expect(find.text('42'), findsOneWidget);
    },
  );

  testWidgets(
    'member_storage renders as a sibling section naming a real member, '
    'never inside the aggregate stats',
    (tester) async {
      final client = MockClient((request) async {
        if (request.url.path == '/users') {
          return http.Response(
            jsonEncode([
              {
                'id': 'nia',
                'username': 'nia',
                'display_name': 'Nia',
                'created_at': 0,
                'role_ids': <String>[],
                'roles': <String>[],
              },
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            ..._enabledBody,
            'member_storage': [
              {'user_id': 'nia', 'attachment_bytes': 5000},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      expect(find.text('Attachment storage by member'), findsOneWidget);
      expect(find.text('Nia'), findsOneWidget);
      expect(find.text('4.9 KB'), findsOneWidget);
    },
  );

  testWidgets(
    'no attachment uploader shows the empty notice, not a blank card',
    (tester) async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(_enabledBody),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      expect(find.text('Attachment storage by member'), findsOneWidget);
      expect(
        find.text('Nobody has uploaded an attachment yet.'),
        findsOneWidget,
      );
    },
  );
}
