// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette's field as filters are typed into it: which word is being
/// typed, and which finished words turn into chips.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_search_query.dart';
import 'package:slimm_app/src/features/palette/providers/palette_query.dart';
import 'package:slimm_app/src/features/palette/widgets/palette_filter_suggestions.dart';

TextEditingValue _at(String text, [int? caret]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: caret ?? text.length),
);

void main() {
  test('the word before the caret, and none right after a space', () {
    expect(wordBeforeCaret(_at('hello from:al')).word, 'from:al');
    expect(wordBeforeCaret(_at('hello from:al')).start, 6);
    expect(wordBeforeCaret(_at('hello ')).word, '');
    expect(wordBeforeCaret(_at('hello world', 3)).word, 'hel');
    expect(wordBeforeCaret(_at('')).word, '');
  });

  test('a finished filter word becomes a chip and leaves no gap', () {
    final taken = takeFinishedFilters(_at('roadmap from:nick draft'));
    expect(taken.filters, [const SearchFilter(SearchKey.from, 'nick')]);
    expect(taken.value.text, 'roadmap draft');
    expect(taken.value.selection.baseOffset, 'roadmap draft'.length);
  });

  test('the word still being typed is never taken, nor a non-filter', () {
    for (final text in ['from:ni', 'has:sticker more', 'hello world']) {
      final taken = takeFinishedFilters(_at(text));
      expect(taken.filters, isEmpty, reason: text);
      expect(taken.value.text, text);
    }
  });

  test('a pasted query becomes all its chips at once, caret kept', () {
    final taken = takeFinishedFilters(
      _at('from:a has:image in:#general hi ', 4),
    );
    expect(
      taken.filters,
      isEmpty,
      reason: 'the caret is inside the first word',
    );

    final all = takeFinishedFilters(_at('from:a has:image in:#general hi '));
    expect(
      [for (final f in all.filters) f.typed],
      ['from:a', 'has:image', 'in:general'],
    );
    expect(all.value.text, 'hi ');
    expect(all.value.selection.baseOffset, 3);
  });

  test('replacing the word before the caret leaves the rest alone', () {
    final next = replaceWordBeforeCaret(_at('hi fr there', 5), 'from:');
    expect(next.text, 'hi from: there');
    expect(next.selection.baseOffset, 8);
  });

  test('quick dates are the searcher\'s own days, counted on the calendar', () {
    final added = <SearchFilter>[];
    final picks = filterSuggestions(
      'during:',
      offerKeys: false,
      sources: (
        members: const [],
        channels: const [],
        today: DateTime(2026, 3, 9, 0, 30),
      ),
      actions: (complete: (_) {}, add: added.add),
    );
    expect([for (final p in picks) p.label].take(3), [
      '2026-03-09',
      '2026-03-08',
      '2026-03',
    ]);
  });

  group('PaletteField', () {
    late int edits;
    late PaletteField field;
    setUp(() {
      edits = 0;
      field = PaletteField(
        filters: const [SearchFilter(SearchKey.inChannel, 'general')],
        onEdited: () => edits++,
      );
      addTearDown(field.dispose);
    });

    test('typing a key and a space makes a chip after the scope', () {
      field.controller.value = _at('from:nick ');
      field.typed();
      expect(
        [for (final f in field.filters) f.typed],
        ['in:general', 'from:nick'],
      );
      expect(field.text, '');
      expect(edits, 1);
    });

    test('a key in the field means its value is being typed', () {
      field.controller.value = _at('notes has:im');
      expect(field.typingValue, isTrue);
      field.controller.value = _at('notes hasty');
      expect(field.typingValue, isFalse);
    });

    test('a picked value replaces the word that asked for it', () {
      field.controller.value = _at('notes from:ni');
      field.add(const SearchFilter(SearchKey.from, 'nick', label: 'Nick'));
      expect(field.text, 'notes ');
      expect(field.filters.last.label, 'Nick');
    });
  });
}
