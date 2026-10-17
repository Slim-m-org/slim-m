// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "which messages wake a device" row `NotificationsSection` gained:
/// it reads the real value back from `GET /push/preference` (unlike
/// presence, which only ever echoes a local choice), a change round-trips
/// through `PUT`, and a server too old to have the route (a plain 404)
/// makes the row disappear rather than offering a choice that would just
/// fail on every tap.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_status_sections.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Widget _harness(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const Scaffold(
      body: SingleChildScrollView(child: NotificationsSection()),
    ),
  ),
);

ProviderContainer _containerWith(
  Future<http.Response> Function(http.Request) handler,
) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(handler),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  return container;
}

http.Response _json(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('shows the preference GET /push/preference answers with', (
    tester,
  ) async {
    final container = _containerWith((request) async {
      if (request.url.path == '/push/preference') {
        return _json({'preference': 'mentions'});
      }
      return http.Response('', 404);
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();

    expect(find.text('Mentions and direct messages'), findsOneWidget);
  });

  testWidgets('choosing a new preference sends it and refetches', (
    tester,
  ) async {
    var stored = 'everything';
    final requests = <String>[];
    final container = _containerWith((request) async {
      requests.add('${request.method} ${request.url.path}');
      if (request.method == 'PUT' && request.url.path == '/push/preference') {
        stored =
            (jsonDecode(request.body) as Map<String, dynamic>)['preference']
                as String;
        return _json({'preference': stored});
      }
      if (request.url.path == '/push/preference') {
        return _json({'preference': stored});
      }
      return http.Response('', 404);
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();
    expect(find.text('All messages'), findsOneWidget);

    await tester.tap(find.text('All messages'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nothing'));
    await tester.pumpAndSettle();

    expect(requests, contains('PUT /push/preference'));
    expect(stored, 'nothing');
    expect(find.text('Nothing'), findsOneWidget);
  });

  testWidgets('choosing mentions and direct messages sends that value', (
    tester,
  ) async {
    var stored = 'everything';
    final container = _containerWith((request) async {
      if (request.method == 'PUT' && request.url.path == '/push/preference') {
        stored =
            (jsonDecode(request.body) as Map<String, dynamic>)['preference']
                as String;
      }
      return request.url.path == '/push/preference'
          ? _json({'preference': stored})
          : http.Response('', 404);
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All messages'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mentions and direct messages'));
    await tester.pumpAndSettle();

    expect(stored, 'mentions');
  });

  testWidgets(
    'a server predating the route (a bare 404) hides the row entirely',
    (tester) async {
      final container = _containerWith(
        (request) async => http.Response('', 404),
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(container));
      await tester.pumpAndSettle();

      expect(find.text('Notify me for'), findsNothing);
      expect(find.text('All messages'), findsNothing);
    },
  );

  testWidgets(
    'a genuine fetch failure shows a retryable error, not a silent Unknown',
    (tester) async {
      // Only /push/preference fails; /notifications/schedule succeeds so its own error state stays out of this test.
      final container = _containerWith((request) async {
        if (request.url.path == '/notifications/schedule') {
          return _json({'schedule': null});
        }
        return http.Response('', 500);
      });
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(container));
      await tester.pumpAndSettle();

      // The row still renders ("Unknown"), but the failure is visible with a way back.
      expect(find.text('Notify me for'), findsOneWidget);
      expect(
        find.text('Could not load your notification preference.'),
        findsOneWidget,
      );
      expect(find.byType(AppErrorState), findsOneWidget);
    },
  );

  testWidgets('retrying after a fetch failure re-fetches the preference', (
    tester,
  ) async {
    var attempt = 0;
    final container = _containerWith((request) async {
      if (request.url.path != '/push/preference') return http.Response('', 404);
      attempt++;
      if (attempt == 1) return http.Response('', 500);
      return _json({'preference': 'nothing'});
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();
    expect(find.byType(AppErrorState), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsNothing);
    expect(find.text('Nothing'), findsOneWidget);
  });
}
