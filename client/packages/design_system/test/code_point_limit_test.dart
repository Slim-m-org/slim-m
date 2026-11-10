// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The field's cap counts code points, the server's unit, not grapheme
/// clusters, which is what lets a field and the server agree on emoji.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

TextEditingValue _edit(String before, String after) =>
    CodePointLengthLimit(4).formatEditUpdate(
      TextEditingValue(text: before),
      TextEditingValue(
        text: after,
        selection: TextSelection.collapsed(offset: after.length),
      ),
    );

TextEditingValue _limit(TextEditingValue after) =>
    CodePointLengthLimit(4).formatEditUpdate(const TextEditingValue(), after);

void main() {
  test('text within the cap passes untouched', () {
    expect(_edit('abc', 'abcd').text, 'abcd');
  });

  test('a paste past the cap is cut to fit, not dropped', () {
    final cut = _edit('', 'abcdefgh');
    expect(cut.text, 'abcd');
    expect(cut.selection.baseOffset, 4);
  });

  test('a multi-code-point emoji counts every code point', () {
    // One visible family emoji, seven code points: man, ZWJ, woman, ZWJ, girl, ZWJ, boy.
    const family =
        '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}';
    expect(family.runes.length, 7);
    expect(_edit('', family).text.runes.length, 4);
  });

  test('a composition inside the cut survives it', () {
    final cut = _limit(
      const TextEditingValue(
        text: 'abcdefgh',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 1, end: 3),
      ),
    );
    expect(cut.composing, const TextRange(start: 1, end: 3));
  });

  test('a composition crossing the cut is clamped to the new length', () {
    final cut = _limit(
      const TextEditingValue(
        text: 'abcdefgh',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 2, end: 8),
      ),
    );
    expect(cut.composing, const TextRange(start: 2, end: 4));
  });

  test('a composition that starts past the cut is dropped', () {
    final cut = _limit(
      const TextEditingValue(
        text: 'abcdefgh',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 5, end: 8),
      ),
    );
    expect(cut.composing, TextRange.empty);
  });

  test('a selection keeps its extent and direction, clamped to the cut', () {
    final cut = _limit(
      const TextEditingValue(
        text: 'abcdefgh',
        selection: TextSelection(baseOffset: 6, extentOffset: 1),
      ),
    );
    expect(cut.selection.baseOffset, 4);
    expect(cut.selection.extentOffset, 1);
  });

  testWidgets('AppInput refuses typing past maxLength', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: AppInput(controller: controller, maxLength: 5),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'abcdefghij');
    expect(controller.text, 'abcde');
  });

  testWidgets('counterMax shows trimmed code points and lets typing run past', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: AppInput(controller: controller, counterMax: 3),
        ),
      ),
    );
    expect(find.text('0/3'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  \u{1F600}b  ');
    await tester.pump();
    expect(find.text('2/3'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'abcde');
    await tester.pump();
    expect(controller.text, 'abcde');
    final over = tester.widget<Text>(find.text('5/3'));
    expect(over.style?.color, AppTokens.light.dangerText);
  });

  testWidgets('counterMax tracks a field with no controller', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: AppInput(counterMax: 10)),
      ),
    );
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(find.text('5/10'), findsOneWidget);
  });

  testWidgets('the counter never joins the field label', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: AppInput(semanticLabel: 'Channel name', counterMax: 64),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Channel name'), findsOneWidget);
    expect(find.bySemanticsLabel('0/64'), findsOneWidget);
    semantics.dispose();
  });
}
