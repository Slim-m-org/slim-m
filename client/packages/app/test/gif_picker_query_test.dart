// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picker's query box: clearing it falls back to trending, and typing is
/// debounced into one search.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/gif_picker.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _results(String id, String title) => http.Response(
  jsonEncode({
    'results': [
      {'id': id, 'title': title, 'width': 100, 'height': 100},
    ],
  }),
  200,
  headers: {'content-type': 'application/json'},
);

Future<List<String>> _pump(WidgetTester tester) async {
  final queries = <String>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            final path = request.url.path;
            if (path == '/gifs/trending') {
              return _results('tok-trending', 'trending cat');
            }
            if (path == '/gifs/search') {
              queries.add(request.url.queryParameters['q'] ?? '');
              return _results('tok-search', 'searched dog');
            }
            return http.Response('unexpected $path', 500);
          }),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: GifPickerBody(onPicked: (_) {})),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return queries;
}

Finder _tile(String title) => find.bySemanticsLabel('Pick: $title');

void main() {
  testWidgets('clearing the query falls back to the trending grid', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final queries = await _pump(tester);
    expect(_tile('trending cat'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'dog');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(_tile('searched dog'), findsOneWidget);
    expect(_tile('trending cat'), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    expect(_tile('trending cat'), findsOneWidget);
    expect(_tile('searched dog'), findsNothing);
    expect(queries, ['dog'], reason: 'clearing is not a search for nothing');
    handle.dispose();
  });

  testWidgets('typing within the debounce sends a single search', (
    tester,
  ) async {
    final queries = await _pump(tester);

    await tester.enterText(find.byType(TextField), 'd');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'do');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'dog');
    await tester.pump(const Duration(milliseconds: 100));
    expect(queries, isEmpty, reason: 'still inside the debounce window');

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(queries, ['dog']);
  });
}
