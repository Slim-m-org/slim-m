// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the composer's markdown key bindings: continuing or ending a
/// list on Enter, and wrapping the selection for bold/italic.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_markdown_shortcuts.dart';

TextEditingValue _valueAt(String text, int caret) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: caret),
);

void main() {
  group('continueList', () {
    test('a non-empty bullet item continues with the same marker', () {
      final value = _valueAt('- one', 5);
      final next = continueList(value);
      expect(next!.text, '- one\n- ');
      expect(next.selection.baseOffset, next.text.length);
    });

    test('a non-empty numbered item continues with the next number', () {
      final value = _valueAt('1. one', 6);
      final next = continueList(value);
      expect(next!.text, '1. one\n2. ');
    });

    test(
      'a numbered item preserves whatever number came before it, plus one',
      () {
        final value = _valueAt('7. seventh', 10);
        final next = continueList(value);
        expect(next!.text, '7. seventh\n8. ');
      },
    );

    test('a nested (two-space indented) item continues at the same depth', () {
      final value = _valueAt('  - nested', 10);
      final next = continueList(value);
      expect(next!.text, '  - nested\n  - ');
    });

    test('an empty bullet item ends the list by removing the marker, rather '
        'than continuing it', () {
      final value = _valueAt('- ', 2);
      final next = continueList(value);
      expect(next!.text, '');
      expect(next.selection.baseOffset, 0);
    });

    test('an empty item ending a list leaves an earlier line untouched', () {
      final value = _valueAt('- one\n- ', 8);
      final next = continueList(value);
      expect(next!.text, '- one\n');
      expect(next.selection.baseOffset, 6);
    });

    test('a line that is not a list item is left alone, so an ordinary '
        'newline applies instead', () {
      final value = _valueAt('just some text', 9);
      expect(continueList(value), isNull);
    });

    test('a non-collapsed selection is left alone', () {
      final value = const TextEditingValue(
        text: '- one',
        selection: TextSelection(baseOffset: 0, extentOffset: 3),
      );
      expect(continueList(value), isNull);
    });
  });

  group('applyListAwareEnter', () {
    test('falls back to a plain newline when the line is not a list item', () {
      final value = _valueAt('hello', 5);
      final next = applyListAwareEnter(value);
      expect(next.text, 'hello\n');
      expect(next.selection.baseOffset, 6);
    });

    test('continues a list exactly as continueList would', () {
      final value = _valueAt('- one', 5);
      final next = applyListAwareEnter(value);
      expect(next.text, '- one\n- ');
    });
  });

  group('wrapSelectionWithMarker', () {
    test('wraps a selection in the marker on both sides', () {
      final value = const TextEditingValue(
        text: 'say hello world',
        selection: TextSelection(baseOffset: 4, extentOffset: 9),
      );
      final next = wrapSelectionWithMarker(value, '**');
      expect(next.text, 'say **hello** world');
      expect(next.selection.baseOffset, 6);
      expect(next.selection.extentOffset, 11);
    });

    test('inserts an empty pair with the caret left between the markers when '
        'nothing is selected', () {
      final value = _valueAt('say world', 4);
      final next = wrapSelectionWithMarker(value, '*');
      expect(next.text, 'say **world');
      expect(next.selection.isCollapsed, isTrue);
      expect(next.selection.baseOffset, 5);
    });
  });
}
