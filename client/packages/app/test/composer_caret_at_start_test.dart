// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/composer_list_indent.dart';
import 'package:slimm_app/src/widgets/composer_markdown_shortcuts.dart';

TextEditingValue _at(String text, int offset) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: offset),
);

void main() {
  group('lineStartAt', () {
    test('the start of the text is its own line start', () {
      expect(lineStartAt('', 0), 0);
      expect(lineStartAt('abc', 0), 0);
    });

    test('a caret after a newline starts that line', () {
      expect(lineStartAt('ab\ncd', 3), 3);
      expect(lineStartAt('ab\ncd', 5), 3);
      expect(lineStartAt('ab\ncd', 2), 0);
    });
  });

  group('with the caret at the start of the text', () {
    test('leaveEmptyItem finds no empty item and does not throw', () {
      expect(leaveEmptyItem(_at('- a', 0)), isNull);
      expect(leaveEmptyItem(_at('', 0)), isNull);
    });

    test('continueList finds no list line and does not throw', () {
      expect(continueList(_at('abc', 0)), isNull);
    });

    test('Shift+Enter inserts a newline in front of the text', () {
      final value = applyListAwareEnter(_at('abc', 0));
      expect(value.text, '\nabc');
      expect(value.selection.baseOffset, 1);
    });
  });
}
