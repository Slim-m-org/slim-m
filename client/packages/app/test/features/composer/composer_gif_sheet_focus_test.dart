// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opening the GIF tab on a phone shows the GIFs; it does not raise the keyboard.
///
/// The search field took focus on every open, so a reader who only meant to
/// browse got the keyboard over the grid. A `/gif cats` query still focuses
/// it, since that reader is already typing.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_picker_panel.dart';
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
        jsonEncode({'results': <Object>[]}),
        200,
        headers: {'content-type': 'application/json'},
      ),
    ),
  ],
);

Future<void> _openSheet(WidgetTester tester, {String gifQuery = ''}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
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
                  gifQuery: gifQuery,
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
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool _searchFocused(WidgetTester tester) => tester
    .widgetList<EditableText>(find.byWidgetPredicate((w) => w is EditableText))
    .any((field) => field.focusNode.hasFocus);

void main() {
  testWidgets('browsing GIFs on a phone leaves the keyboard down', (
    tester,
  ) async {
    await _openSheet(tester);
    expect(_searchFocused(tester), isFalse);
  });

  testWidgets('a /gif query still puts the cursor in the search', (
    tester,
  ) async {
    await _openSheet(tester, gifQuery: 'cats');
    expect(_searchFocused(tester), isTrue);
  });
}
