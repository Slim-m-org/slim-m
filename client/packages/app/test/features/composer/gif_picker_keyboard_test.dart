// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gif panel has to fit beside the keyboard it raises itself.
///
/// The search field autofocuses, so the keyboard is up the whole time this
/// picker is open - it is not an edge case, it is every time. A grid ceiling
/// tall enough to look right on a roomy screen with no keyboard is exactly
/// the ceiling that puts the last row behind one on a shorter phone.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/composer/widgets/gif_picker.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _result(int i) => {
  'id': 'g$i',
  'title': 'gif $i',
  'width': 100,
  'height': 100,
};

ProviderContainer _container() => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    mockApiOverride((request) async {
      if (request.url.path == '/gifs/trending') {
        return http.Response(
          jsonEncode({
            'results': [for (var i = 0; i < 24; i++) _result(i)],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('', 404);
    }),
  ],
);

/// A short phone with the keyboard up: 640 logical tall, 300 of it keyboard.
Future<void> _pumpCramped(WidgetTester tester) async {
  final container = _container();
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 640),
            viewInsets: EdgeInsets.only(bottom: 300),
          ),
          // Left on, Scaffold strips the very inset the widget must see.
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 300),
                child: GifPickerBody(onPicked: (_) {}),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the panel fits in what the keyboard leaves', (tester) async {
    await _pumpCramped(tester);

    expect(
      tester.takeException(),
      isNull,
      reason: 'a grid taller than the room left overflows its column',
    );

    final panel = tester.getRect(find.byType(GifPickerBody));
    expect(
      panel.height,
      lessThanOrEqualTo(340),
      reason:
          'on a 640-tall phone with 300 of keyboard there are 340 logical '
          'pixels to work with, and the panel has to live inside them',
    );
  });
}
