// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The operator storage screen: `GET /space/storage`. Exercises the real
/// `fetchSpaceStorage` client binding through `SlimmApi` (a `MockClient`
/// intercepts the HTTP call itself), the same shape
/// `analytics_screen_test.dart` uses for `spaceAnalytics`.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/screens/admin/storage_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Byte totals are chosen so every tile's formatted text is distinct: a
/// database and total that both round to "1.0 MB" would make findsOneWidget
/// ambiguous rather than proving each tile shows its own number.
const _body = {
  'database_bytes': 500000,
  'database_reclaimable_bytes': 4096,
  'attachment_bytes': 2048,
  'top_channels': [
    {'channel_id': 'c1', 'name': 'heavy', 'attachment_bytes': 1500},
  ],
  'sweeps': [
    {'name': 'token', 'last_run_at': 1000, 'last_reclaimed': 3},
  ],
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
    home: const Scaffold(body: StorageScreen()),
  ),
);

void main() {
  testWidgets('renders totals, top channels and sweep status as text', (
    tester,
  ) async {
    var requestedPath = '';
    final client = MockClient((request) async {
      requestedPath = request.url.path;
      return http.Response(
        jsonEncode(_body),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final container = _containerFor(client);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(requestedPath, '/space/storage');
    expect(find.text('490.3 KB'), findsOneWidget); // total on disk
    expect(find.text('488.3 KB of 490.3 KB'), findsOneWidget); // database
    expect(find.text('2.0 KB of 490.3 KB'), findsOneWidget); // attachments
    expect(find.text('4.0 KB of 488.3 KB database'), findsOneWidget);
    expect(find.text('#heavy'), findsOneWidget);
    expect(find.text('1.5 KB'), findsOneWidget); // that channel's own bytes
    expect(find.text('Expired sessions'), findsOneWidget);
    expect(find.textContaining('3 row(s) removed'), findsOneWidget);
  });

  testWidgets('an empty deployment shows the empty notices, not blank cards', (
    tester,
  ) async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'database_bytes': 20480,
          'database_reclaimable_bytes': 0,
          'attachment_bytes': 0,
          'top_channels': <Map<String, dynamic>>[],
          'sweeps': <Map<String, dynamic>>[],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final container = _containerFor(client);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(
      find.text('No channel has any stored attachments yet.'),
      findsOneWidget,
    );
    expect(
      find.text('No sweep has run yet on this deployment.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'a failed fetch surfaces through the persistent error state, never a '
    'SnackBar',
    (tester) async {
      final client = MockClient((request) async {
        return http.Response('', 500);
      });
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      expect(find.text('Could not load storage usage.'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    },
  );
}
