// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Text the server would refuse for a status or About, a zalgo carrying a
/// combining grapheme joiner or a status past its limit, is caught before it is
/// sent: the field says why, and the status already set is never touched.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
import 'package:slimm_test_support/source_gates.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

int _hex(Object? value) => int.parse(value! as String, radix: 16);

/// A light zalgo with U+034F among its marks, as a zalgo generator draws them.
const _zalgo = 'Z\u0301\u034F\u0316a\u0300\u0353l\u0352g\u0350o\u0345';

/// A word with a zero width space inside it, which nothing draws or needs.
const _hidden = 'new\u200Bhere';

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
    final fixture =
        jsonDecode(
              File(
                '${findRepoRoot().path}/crates/slimm-server/tests/fixtures/hidden_chars.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;

    test('a combining grapheme joiner passes among marks, not on its own', () {
      expect(hidesTextOutsideEmoji(_zalgo), isFalse);
      expect(hidesTextOutsideEmoji('Z\u0301a\u0300l\u0352g\u0350o'), isFalse);
      expect(hidesTextOutsideEmoji('ok \u034F'), isTrue);
    });

    // Each section of the shared fixture with allowed and refused text is a case list for the server's own check.
    for (final MapEntry(key: name, value: section) in fixture.entries) {
      if (section case {
        'allowed': final List<dynamic> allowed,
        'refused': final List<dynamic> refused,
      }) {
        test('agrees with the server on the fixture\'s $name', () {
          expect([
            for (final text in allowed.cast<String>())
              if (hidesTextOutsideEmoji(text)) text,
          ], isEmpty);
          expect([
            for (final text in refused.cast<String>())
              if (!hidesTextOutsideEmoji(text)) text,
          ], isEmpty);
        });
      }
    }

    test('every code point agrees on which are emoji', () {
      final ranges = [
        for (final r
            in (fixture['pictographic'] as List).cast<Map<String, dynamic>>())
          (_hex(r['from']), _hex(r['to'])),
      ];
      final wrong = <String>[];
      for (var c = 0; c <= 0x10FFFF; c++) {
        if (c >= 0xD800 && c <= 0xDFFF) continue;
        final expected = ranges.any((r) => c >= r.$1 && c <= r.$2);
        if (isPictographic(c) != expected) {
          wrong.add('U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}');
        }
      }
      expect(wrong, isEmpty, reason: 'disagree with hidden_chars.json');
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

    await tester.enterText(_field('Status text'), _hidden);
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
    await tester.enterText(_field('About'), _hidden);
    await tester.tap(_field('Pronouns'));
    await pumpFrames(tester);

    expect(patches, isEmpty);
    expect(find.text(hiddenCharactersRefusal), findsOneWidget);
  });
}
