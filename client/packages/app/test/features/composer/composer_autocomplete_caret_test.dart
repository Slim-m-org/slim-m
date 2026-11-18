// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The suggestion list follows the caret: once the caret leaves the trigger
/// it typed, by a click, the arrow keys or a selection, the list closes, in an
/// ordinary draft and in one past the message limit alike.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' show kMessageMaxChars;
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete.dart';

import 'composer_harness.dart';

final _list = find.bySubtype<ComposerAutocomplete>();
Finder get _row =>
    find.descendant(of: _list, matching: find.text(':party_parrot:'));

void main() {
  late TextEditingController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
  });

  tearDown(() => controller.dispose());

  Future<void> open(WidgetTester tester, String before) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: Sends(),
        platform: TargetPlatform.linux,
        customEmoji: [custom('party_parrot')],
      ),
    );
    final field = find.bySubtype<EditableText>();
    await tester.tap(field);
    await tester.enterText(field, '$before:party');
    await tester.pump();
    expect(_row, findsOneWidget);
  }

  for (final (name, before) in [
    ('a short draft', 'hi '),
    ('an over-limit draft', '${'a' * (kMessageMaxChars + 20)} '),
  ]) {
    testWidgets('$name: a click back before the trigger closes the list', (
      tester,
    ) async {
      await open(tester, before);
      controller.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      expect(_row, findsNothing);
    });

    testWidgets('$name: arrowing out of the trigger closes the list', (
      tester,
    ) async {
      await open(tester, before);
      for (var i = 0; i < ':party'.length + 1; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      }
      await tester.pump();
      expect(_row, findsNothing);
    });

    testWidgets('$name: a selection reaching out of the trigger closes it', (
      tester,
    ) async {
      await open(tester, before);
      final end = controller.text.length;
      controller.selection = TextSelection(baseOffset: end, extentOffset: 1);
      await tester.pump();
      expect(_row, findsNothing);
    });
  }
}
