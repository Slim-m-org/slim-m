// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Text the server would refuse for a status or About, a zalgo carrying a
/// combining grapheme joiner or a status past its limit, is caught before it is
/// sent: the field says why, and the status already set is never touched.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/widgets/presence_status_field.dart';
import 'package:slimm_app/src/features/members/widgets/profile_fields_section.dart';
import 'package:slimm_app/src/hidden_characters.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A light zalgo with U+034F among its marks, as a zalgo generator draws them.
const _zalgo = 'Z\u0301\u034F\u0316a\u0300\u0353l\u0352g\u0350o\u0345';

Future<List<String>> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final patches = <String>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        if (request.method == 'PATCH') patches.add(request.body);
        return http.Response(
          jsonEncode({
            'id': 'self',
            'username': 'ava',
            'display_name': 'Ava',
            'created_at': 0,
            'permissions': 0,
            'status_text': 'new here, exploring',
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await pumpFrames(tester);
  return patches;
}

Finder _field(String label) => find
    .descendant(
      of: find.bySemanticsLabel(RegExp('^$label')),
      matching: find.byWidgetPredicate((w) => w is EditableText),
    )
    .first;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('hidesTextOutsideEmoji', () {
    test('a combining grapheme joiner in a zalgo is refused', () {
      expect(hidesTextOutsideEmoji(_zalgo), isTrue);
      expect(hidesTextOutsideEmoji('Z\u0301a\u0300l\u0352g\u0350o'), isFalse);
    });

    test('joined emoji and subdivision flags pass, a bare joiner does not', () {
      expect(
        hidesTextOutsideEmoji('\u{1F468}\u200D\u{1F469}\u200D\u{1F467}'),
        isFalse,
      );
      expect(
        hidesTextOutsideEmoji(
          '\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}',
        ),
        isFalse,
      );
      expect(hidesTextOutsideEmoji('a\u200Db'), isTrue);
      expect(hidesTextOutsideEmoji('\u{E0067}'), isTrue);
    });
  });

  testWidgets('a status with a hidden character says so and sends nothing', (
    tester,
  ) async {
    var closed = false;
    final patches = await _pump(
      tester,
      PresenceStatusField(
        current: 'new here, exploring',
        onDone: () => closed = true,
      ),
    );

    await tester.enterText(_field('Status text'), _zalgo);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFrames(tester);

    expect(patches, isEmpty);
    expect(closed, isFalse);
    expect(find.text(hiddenCharactersRefusal), findsOneWidget);
  });

  testWidgets('a status past the limit says so rather than doing nothing', (
    tester,
  ) async {
    final patches = await _pump(
      tester,
      PresenceStatusField(current: '', onDone: () {}),
    );

    await tester.enterText(_field('Status text'), 'x' * 81);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFrames(tester);

    expect(patches, isEmpty);
    expect(find.text('A status can be at most 80 characters.'), findsOneWidget);
  });

  testWidgets('an About with a hidden character says so and sends nothing', (
    tester,
  ) async {
    final patches = await _pump(tester, const ProfileFieldsSection());

    await tester.tap(_field('About'));
    await tester.enterText(_field('About'), _zalgo);
    await tester.tap(_field('Pronouns'));
    await pumpFrames(tester);

    expect(patches, isEmpty);
    expect(find.text(hiddenCharactersRefusal), findsOneWidget);
  });
}
