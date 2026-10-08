// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The emoji settings list is searchable by name.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/emoji_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

Map<String, dynamic> _json(String id, String name) => {
  'id': id,
  'name': name,
  'uploader_id': 'self',
  'created_at': 1700000000000,
};

class _Server {
  _Server(this.emoji);

  final List<Map<String, dynamic>> emoji;
  final seen = <String>[];

  http.Client client() => MockClient((request) async {
    seen.add('${request.method} ${request.url.path}');
    const json = {'content-type': 'application/json'};
    if (request.url.path == '/emoji' && request.method == 'GET') {
      return http.Response(jsonEncode(emoji), 200, headers: json);
    }
    if (request.url.path == '/emoji' && request.method == 'POST') {
      return http.Response('{}', 201, headers: json);
    }
    if (request.url.path.endsWith('/image')) {
      return http.Response.bytes(
        _png,
        200,
        headers: const {'content-type': 'image/png'},
      );
    }
    return http.Response('', request.method == 'DELETE' ? 204 : 404);
  });
}

Future<void> _pump(
  WidgetTester tester,
  _Server server, {
  Size size = const Size(1280, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: server.client(),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const EmojiScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _search => find.widgetWithText(AppInput, 'Search emoji');

void main() {
  for (final size in const [Size(390, 844), Size(1280, 900)]) {
    testWidgets('searching the list filters by name at ${size.width.toInt()}', (
      tester,
    ) async {
      final server = _Server([
        _json('e1', 'party_parrot'),
        _json('e2', 'ok_hand'),
        _json('e3', 'parrot_dance'),
      ]);
      await _pump(tester, server, size: size);
      expect(find.text(':ok_hand:'), findsOneWidget);

      await tester.enterText(_search, ':PARR');
      await tester.pumpAndSettle();

      expect(find.text(':party_parrot:'), findsOneWidget);
      expect(find.text(':parrot_dance:'), findsOneWidget);
      expect(find.text(':ok_hand:'), findsNothing);
    });
  }

  testWidgets('a search with no match says so, and clearing restores', (
    tester,
  ) async {
    await _pump(tester, _Server([_json('e1', 'party_parrot')]));
    final field = _search;

    await tester.enterText(field, 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No emoji match "zzz".'), findsOneWidget);
    expect(find.text(':party_parrot:'), findsNothing);

    await tester.enterText(field, '');
    await tester.pumpAndSettle();
    expect(find.text(':party_parrot:'), findsOneWidget);
  });
}
