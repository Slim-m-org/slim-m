// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A search reply that lands after the box moved on must not repaint the grid.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/gif_picker.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _results(String title) => http.Response(
  jsonEncode({
    'results': [
      {'id': 'tok-$title', 'title': title, 'width': 100, 'height': 100},
    ],
  }),
  200,
  headers: {'content-type': 'application/json'},
);

final _queryField = find.byWidgetPredicate((w) => w is EditableText);

Finder _tile(String title) => find.bySemanticsLabel('Pick: $title');

/// Mounts the picker with every search held open until its completer is completed.
Future<Map<String, Completer<http.Response>>> _pump(WidgetTester tester) async {
  final held = <String, Completer<http.Response>>{};
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) {
        if (request.url.path == '/gifs/trending') {
          return Future.value(_results('trending cat'));
        }
        if (request.url.path != '/gifs/search') {
          return Future.value(http.Response('unexpected', 500));
        }
        final query = request.url.queryParameters['q'] ?? '';
        return (held[query] = Completer<http.Response>()).future;
      }),
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
  await tester.pump(const Duration(milliseconds: 50));
  return held;
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_queryField, text);
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _reply(
  WidgetTester tester,
  Completer<http.Response> held,
  http.Response response,
) async {
  held.complete(response);
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('an older search finishing last does not replace the newer one', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final held = await _pump(tester);

    await _type(tester, 'cat');
    await _type(tester, 'cats');
    await _reply(tester, held['cats']!, _results('cats result'));
    await _reply(tester, held['cat']!, _results('cat result'));

    expect(_tile('cats result'), findsOneWidget);
    expect(_tile('cat result'), findsNothing);
    handle.dispose();
  });

  testWidgets('a search finishing after the box was cleared stays hidden', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final held = await _pump(tester);
    expect(_tile('trending cat'), findsOneWidget);

    await _type(tester, 'cat');
    await _type(tester, '');
    await _reply(tester, held['cat']!, _results('cat result'));

    expect(_tile('trending cat'), findsOneWidget);
    expect(_tile('cat result'), findsNothing);
    handle.dispose();
  });

  testWidgets('an older search failing late does not raise its error', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final held = await _pump(tester);

    await _type(tester, 'cat');
    await _type(tester, 'cats');
    await _reply(tester, held['cats']!, _results('cats result'));
    await _reply(tester, held['cat']!, http.Response('{}', 503));

    expect(_tile('cats result'), findsOneWidget);
    expect(find.textContaining('search for gifs'), findsNothing);
    handle.dispose();
  });
}
