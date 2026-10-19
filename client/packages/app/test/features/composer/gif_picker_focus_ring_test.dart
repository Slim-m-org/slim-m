// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tabbing through the gif grid worked but showed nothing, so a keyboard user
/// could not tell which gif Enter would send. A focused tile draws the ring.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/composer/widgets/gif_picker.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  testWidgets('the gif tile keyboard focus lands on shows a focus ring', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          if (request.url.path == '/gifs/trending') {
            return http.Response(
              jsonEncode({
                'results': [
                  for (var i = 0; i < 6; i++)
                    {
                      'id': 'g$i',
                      'title': 'gif $i',
                      'width': 100,
                      'height': 100,
                    },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('', 404);
        }),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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
    expect(find.byKey(const ValueKey('gif-tile-focus-ring')), findsNothing);

    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      if (find
          .byKey(const ValueKey('gif-tile-focus-ring'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }

    expect(find.byKey(const ValueKey('gif-tile-focus-ring')), findsOneWidget);
  });
}
