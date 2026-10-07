// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opening the emoji and GIF picker fetches trending GIFs and the first
/// thumbnails straight away, so the GIFs tab is not empty on first view.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/composer_picker_panel.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

// The smallest valid PNG, so a thumbnail decodes if anything draws it.
final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  ),
);

Future<List<String>> _openPicker(
  WidgetTester tester, {
  required bool showGifTab,
}) async {
  final requests = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              requests.add(request.url.path);
              if (request.url.path == '/gifs/trending') {
                return http.Response(
                  jsonEncode({
                    'results': [
                      for (var i = 0; i < 10; i++)
                        {
                          'id': 'g$i',
                          'title': 'gif $i',
                          'width': 64,
                          'height': 64,
                        },
                    ],
                  }),
                  200,
                  headers: const {'content-type': 'application/json'},
                );
              }
              if (request.url.path.startsWith('/gifs/preview/')) {
                return http.Response.bytes(
                  _png,
                  200,
                  headers: const {'content-type': 'image/png'},
                );
              }
              return http.Response('{}', 200);
            }),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Center(
            child: ComposerPickerPanel(
              initialTab: ComposerPickerTab.emoji,
              showGifTab: showGifTab,
              onSelectEmoji: (_) {},
              onPickedGif: (_) {},
              onClose: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
  return requests;
}

void main() {
  testWidgets(
    'opening the picker on Emoji fetches trending GIFs and the first thumbnails',
    (tester) async {
      final requests = await _openPicker(tester, showGifTab: true);
      expect(requests.where((p) => p == '/gifs/trending'), hasLength(1));
      expect(
        requests.where((p) => p.startsWith('/gifs/preview/')).length,
        greaterThanOrEqualTo(4),
        reason: 'the first row of thumbnails is warm before the GIFs tab opens',
      );
    },
  );

  testWidgets('a deployment with no GIF search fetches nothing', (
    tester,
  ) async {
    final requests = await _openPicker(tester, showGifTab: false);
    expect(requests.where((p) => p.startsWith('/gifs/')), isEmpty);
  });
}
