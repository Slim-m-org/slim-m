// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A deployment with a couple of emoji packs pushes this screen well past
/// what a plain, eagerly-built list can afford: `MAX_CUSTOM_EMOJI` allows up
/// to 500. This pins the fix at that scale rather than asserting a flag -
/// the same `itemBuilder`-count technique `sheet_item_list_test.dart` uses,
/// through the one proxy available from outside the screen's private row
/// widget: one delete icon exists per row actually realized.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/screens/admin/emoji_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

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

/// Two packs' worth, the size the report named.
const _emojiCount = 400;

List<Map<String, dynamic>> _bigCatalog() => [
  for (var i = 0; i < _emojiCount; i++)
    {
      'id': 'emoji-$i',
      'name': 'e$i',
      'uploader_id': 'self',
      'created_at': 1700000000000,
    },
];

http.Client _server() => MockClient((request) async {
  final path = request.url.path;
  if (path == '/emoji') {
    return http.Response(
      jsonEncode(_bigCatalog()),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
  if (path.endsWith('/image')) {
    return http.Response.bytes(
      _png,
      200,
      headers: const {'content-type': 'image/png'},
    );
  }
  return http.Response('{}', 404);
});

void main() {
  testWidgets(
    'a catalog past MAX_CUSTOM_EMOJI realizes only the rows on screen',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: _server(),
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

      final realized = find.byIcon(AppIcons.delete).evaluate().length;
      expect(
        realized,
        lessThan(50),
        reason:
            'a bounded lazy list must only realize the handful of rows '
            'actually visible, not the whole $_emojiCount-emoji catalog',
      );
      expect(
        realized,
        greaterThan(0),
        reason: 'the catalog must still render something',
      );
    },
  );
}
