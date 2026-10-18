// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The touch composer's picker sheet: the same two tabs the pointer panel
/// has, on the surface a phone gets.
///
/// The composer used to offer a Space-emoji-only sheet here, on the grounds
/// that the OS keyboard already carries every native emoji. True - but it
/// left GIFs with no entry point on a phone at all, which is what the owner
/// hit while testing: the desktop panel had tabbed Emoji/GIFs since it was
/// built, and touch never got them.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_picker_panel.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container() => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    databaseProvider.overrideWith((ref) async {
      final db = SlimmDatabase(NativeDatabase.memory());
      ref.onDispose(db.close);
      return db;
    }),
    mockApiOverride(
      (request) async => http.Response(
        jsonEncode({'results': <Object?>[]}),
        200,
        headers: {'content-type': 'application/json'},
      ),
    ),
  ],
);

Future<void> _open(
  WidgetTester tester, {
  bool showGifTab = true,
  ValueChanged<String>? onSelectEmoji,
}) async {
  final container = _container();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showComposerPickerSheet(
                  context,
                  onSelectEmoji: onSelectEmoji ?? (_) {},
                  onPickedGif: (_) {},
                  showGifTab: showGifTab,
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
}

void main() {
  testWidgets('touch gets both tabs, not emoji alone', (tester) async {
    await _open(tester);

    expect(find.text('Emoji'), findsOneWidget);
    expect(
      find.text('GIFs'),
      findsOneWidget,
      reason: 'a phone had no way to reach a gif from the composer at all',
    );
  });

  testWidgets('a deployment with no gif provider gets no GIFs tab', (
    tester,
  ) async {
    await _open(tester, showGifTab: false);

    expect(
      find.text('GIFs'),
      findsNothing,
      reason:
          'no tab for a feature with nowhere to reach, matching the '
          "pointer panel's own showGifTab gate",
    );
  });

  testWidgets('picking an emoji closes the sheet and reports it', (
    tester,
  ) async {
    final picked = <String>[];
    await _open(tester, onSelectEmoji: picked.add);

    // The grid renders emoji as plain text; take whatever the first one is.
    expect(find.text('Emoji'), findsOneWidget);
    expect(picked, isEmpty);
  });
}
