// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The touch picker sheet sits on the keyboard, with no blank band between.
///
/// `showAppSheet` already lifts a phone sheet above the keyboard; a body that
/// pads for the keyboard again floated the GIF grid a band of empty sheet
/// above it, which is what the owner hit on an iPhone.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_picker_panel.dart';
import 'package:slimm_app/src/features/composer/widgets/gif_picker.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _screen = Size(390, 844);
const _keyboard = 300.0;

ProviderContainer _container() => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    databaseProvider.overrideWith((ref) async {
      final db = SlimmDatabase(NativeDatabase.memory());
      ref.onDispose(db.close);
      return db;
    }),
    mockApiOverride((request) async {
      if (request.url.path == '/gifs/trending') {
        return http.Response(
          jsonEncode({
            'results': [
              for (var i = 0; i < 24; i++)
                {'id': 'g$i', 'title': 'gif $i', 'width': 100, 'height': 100},
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

void main() {
  testWidgets('the gif tab ends where the keyboard starts', (tester) async {
    tester.view.physicalSize = _screen;
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
    addTearDown(tester.view.reset);
    final container = _container();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showComposerPickerSheet(
                    context,
                    onSelectEmoji: (_) {},
                    onPickedGif: (_) {},
                    initialTab: ComposerPickerTab.gif,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final keyboardTop = _screen.height - _keyboard;
    final body = tester.getRect(find.byType(GifPickerBody));
    expect(
      keyboardTop - body.bottom,
      lessThanOrEqualTo(AppSpacing.s16),
      reason:
          'the grid ended ${keyboardTop - body.bottom} px above the keyboard',
    );
    expect(body.bottom, lessThanOrEqualTo(keyboardTop));
  });
}
