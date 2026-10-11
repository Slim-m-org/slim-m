// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space performance screen: that all three capacity controls render
/// together, and the message retention section - its toggle-independence,
/// its patch, and the consequence text stating what a chosen window actually
/// does. The canvas cap and screen-share sections have their own files
/// (`performance_canvas_cap_test.dart`, `performance_screen_share_cap_test
/// .dart`) for the same file-size reason this test does not repeat them.
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
  test('only shortening or starting a window deletes history', () {
    expect(retentionDeletesHistory(from: 0, to: 30), isTrue);
    expect(retentionDeletesHistory(from: 365, to: 90), isTrue);
    expect(retentionDeletesHistory(from: 30, to: 90), isFalse);
    expect(retentionDeletesHistory(from: 30, to: 0), isFalse);
    expect(retentionDeletesHistory(from: 30, to: 30), isFalse);
  });

  testWidgets('renders all three capacity controls together', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/space/retention') {
        return _json({'retention_days': 0});
      }
      if (request.url.path == '/space/canvas-cap') {
        return _json({'object_cap': 20000});
      }
      if (request.url.path == '/space/screen-share') {
        return _json({'max_height': 2160});
      }
      return _json({'enabled': false});
    });
    final container = _containerFor(client);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.text('Message retention'), findsOneWidget);
    expect(find.text('Canvas object cap'), findsOneWidget);
    expect(find.text('Screen share quality'), findsOneWidget);
  });

  testWidgets(
    'the retention section stays visible while analytics itself is off, '
    'and tapping an option patches the window',
    (tester) async {
      var retentionDays = 0;
      final patchedRetention = <int>[];
      final client = MockClient((request) async {
        if (request.url.path == '/space/canvas-cap') {
          return _json({'object_cap': 20000});
        }
        if (request.url.path == '/space/screen-share') {
          return _json({'max_height': 2160});
        }
        if (request.url.path == '/space/retention') {
          if (request.method == 'PATCH') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            retentionDays = body['retention_days'] as int;
            patchedRetention.add(retentionDays);
          }
          return _json({'retention_days': retentionDays});
        }
        return _json({'enabled': false});
      });
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      expect(find.text('Message retention'), findsOneWidget);
      expect(find.textContaining('kept indefinitely'), findsOneWidget);

      await tester.tap(find.text('30 days'));
      await tester.pumpAndSettle();

      expect(find.text('Delete messages older than 30 days?'), findsOneWidget);
      expect(patchedRetention, isEmpty, reason: 'nothing before confirming');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(patchedRetention, isEmpty, reason: 'cancel changes nothing');

      await tester.tap(find.text('30 days'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete old messages'));
      await tester.pumpAndSettle();

      expect(patchedRetention, [30]);
    },
  );

  testWidgets(
    "'Never' states nothing is pruned; a real window states the cutoff and, "
    'with analytics off, says so rather than fabricating a total',
    (tester) async {
      var retentionDays = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/space/canvas-cap') {
          return _json({'object_cap': 20000});
        }
        if (request.url.path == '/space/screen-share') {
          return _json({'max_height': 2160});
        }
        if (request.url.path == '/space/retention') {
          if (request.method == 'PATCH') {
            retentionDays =
                (jsonDecode(request.body) as Map)['retention_days'] as int;
          }
          return _json({'retention_days': retentionDays});
        }
        // Analytics off: no stats to ground a number in.
        return _json({'enabled': false});
      });
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'messages and their attachments are kept indefinitely',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('30 days'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete old messages'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Prunes anything older than'), findsOneWidget);
      expect(
        find.textContaining(
          "Turn on Space analytics to see this space's "
          'current totals',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'grounds the retention consequence in this space\'s real totals once '
    'analytics is on',
    (tester) async {
      final client = MockClient((request) async {
        if (request.url.path == '/space/canvas-cap') {
          return _json({'object_cap': 20000});
        }
        if (request.url.path == '/space/screen-share') {
          return _json({'max_height': 2160});
        }
        if (request.url.path == '/space/retention') {
          return _json({'retention_days': 30});
        }
        return _json({
          'enabled': true,
          'stats': {
            'total_messages': 123,
            'member_count': 3,
            'channel_count': 2,
            'attachment_bytes': 5000,
            'messages_by_day': <Map<String, dynamic>>[],
            'active_hours': List<int>.filled(24, 0),
            'memory_samples': <Map<String, dynamic>>[],
          },
        });
      });
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      expect(find.textContaining('holds 4.9 KB'), findsOneWidget);
      expect(find.textContaining('123 messages'), findsOneWidget);
    },
  );
}
