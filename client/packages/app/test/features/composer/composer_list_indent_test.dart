// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tab, Shift+Tab and empty-item behaviour for composer lists, as pure
/// functions, then the same keys against a real focus tree.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_list_indent.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_list_keys.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_markdown_shortcuts.dart';

TextEditingValue _at(String text, [int? caret]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: caret ?? text.length),
);

void main() {
  group('indentList', () {
    test('indents a bullet by two spaces and keeps the caret on the text', () {
      final next = indentList(_at('- one\n- two', 8))!;
      expect(next.text, '- one\n  - two');
      expect(next.selection.baseOffset, 10);
    });

    test('indents from the start of the line', () {
      final next = indentList(_at('- one\n- two', 6))!;
      expect(next.text, '- one\n  - two');
      expect(next.selection.baseOffset, 8);
    });

    test('stops at three levels but still consumes the key', () {
      final deepest = _at('    - three');
      final next = indentList(deepest)!;
      expect(next.text, '    - three');
    });

    test('is null off a list line, so Tab keeps moving focus', () {
      expect(indentList(_at('plain text')), isNull);
      expect(indentList(_at('')), isNull);
    });

    test('indents every list line a selection touches', () {
      final value = const TextEditingValue(
        text: '- a\n- b\nplain\n- c',
        selection: TextSelection(baseOffset: 2, extentOffset: 16),
      );
      expect(indentList(value)!.text, '  - a\n  - b\nplain\n  - c');
    });

    test('a selection ending at the start of a line leaves that line', () {
      final value = const TextEditingValue(
        text: '- a\n- b',
        selection: TextSelection(baseOffset: 0, extentOffset: 4),
      );
      expect(indentList(value)!.text, '  - a\n- b');
    });

    test('renumbers an indented ordered item to open a sub-list', () {
      final next = indentList(_at('1. a\n2. b\n3. c'))!;
      expect(next.text, '1. a\n2. b\n  1. c');
    });

    test('continues numbering beside an earlier sibling at that depth', () {
      final next = indentList(_at('1. a\n  1. x\n2. b'))!;
      expect(next.text, '1. a\n  1. x\n  2. b');
    });

    test('indents a bullet under a number without touching the number', () {
      final next = indentList(_at('1. a\n- b'))!;
      expect(next.text, '1. a\n  - b');
    });
  });

  group('outdentList', () {
    test('removes two spaces', () {
      final next = outdentList(_at('- one\n    - two'))!;
      expect(next.text, '- one\n  - two');
      expect(next.selection.baseOffset, next.text.length);
    });

    test('is a no-op on a non-empty top-level item, key still consumed', () {
      final value = _at('- one');
      expect(outdentList(value)!.text, '- one');
    });

    test('ends the list at an empty top-level item', () {
      expect(outdentList(_at('- one\n- '))!.text, '- one\n');
    });

    test('renumbers an ordered item that rejoins its parent list', () {
      final next = outdentList(_at('1. a\n2. b\n  1. c'))!;
      expect(next.text, '1. a\n2. b\n3. c');
    });

    test('is null off a list line', () {
      expect(outdentList(_at('plain')), isNull);
    });
  });

  group('empty items', () {
    test('Enter on an empty nested item steps out one level first', () {
      final next = continueList(_at('- a\n  - '))!;
      expect(next.text, '- a\n- ');
      expect(next.selection.baseOffset, next.text.length);
    });

    test('a second Enter then ends the list', () {
      expect(continueList(_at('- a\n- '))!.text, '- a\n');
    });

    test('Enter continues a depth-2 item at depth 2', () {
      expect(continueList(_at('    - deep'))!.text, '    - deep\n    - ');
    });

    test('Backspace on an empty item leaves it like Enter does', () {
      expect(leaveEmptyItem(_at('- a\n    - '))!.text, '- a\n  - ');
      expect(leaveEmptyItem(_at('1. '))!.text, '');
    });

    test('Backspace on an item with text is left to the field', () {
      expect(leaveEmptyItem(_at('- a')), isNull);
      expect(leaveEmptyItem(_at('- a\n- ', 3)), isNull);
    });
  });

  group('keys in a focus tree', () {
    late TextEditingController controller;
    late FocusNode field;
    late FocusNode after;
    late ComposerListKeys keys;

    setUp(() {
      controller = TextEditingController();
      after = FocusNode();
      keys = ComposerListKeys();
      field = FocusNode(onKeyEvent: (_, e) => keys.handle(e, controller));
    });

    tearDown(() {
      controller.dispose();
      field.dispose();
      after.dispose();
    });

    Future<void> pump(WidgetTester tester, String text) async {
      controller.value = _at(text);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextField(
                  controller: controller,
                  focusNode: field,
                  maxLines: null,
                ),
                TextField(focusNode: after),
              ],
            ),
          ),
        ),
      );
      field.requestFocus();
      await tester.pump();
    }

    testWidgets('Tab indents a list item and keeps focus', (tester) async {
      await pump(tester, '- one');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(controller.text, '  - one');
      expect(field.hasFocus, isTrue);
    });

    testWidgets('Shift+Tab outdents and keeps focus', (tester) async {
      await pump(tester, '    - one');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(controller.text, '  - one');
      expect(field.hasFocus, isTrue);
    });

    testWidgets('Tab off a list line moves focus on', (tester) async {
      await pump(tester, 'plain');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(controller.text, 'plain');
      expect(after.hasFocus, isTrue);
    });

    testWidgets('Escape then Tab leaves a list line', (tester) async {
      await pump(tester, '- one');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(controller.text, '- one');
      expect(after.hasFocus, isTrue);
    });

    testWidgets('typing again gives Tab back to the list', (tester) async {
      await pump(tester, '- one');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(controller.text, '  - one');
      expect(field.hasFocus, isTrue);
    });

    testWidgets('Backspace on an empty item removes its marker', (
      tester,
    ) async {
      await pump(tester, '- one\n- ');
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      expect(controller.text, '- one\n');
    });
  });
}
