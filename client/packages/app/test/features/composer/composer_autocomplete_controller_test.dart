// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The autocomplete controller on its own, with no composer pumped.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_controller.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_items.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_query.dart';

const _query = AutocompleteQuery(
  kind: AutocompleteKind.mention,
  term: 'al',
  start: 6,
  end: 9,
);

const _offers = [
  AutocompleteSuggestion(insert: '@alice ', label: 'alice'),
  AutocompleteSuggestion(insert: '@alan ', label: 'alan'),
  AutocompleteSuggestion(insert: '@alma ', label: 'alma'),
];

KeyDownEvent _down(LogicalKeyboardKey key) => KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.keyA,
  logicalKey: key,
  timeStamp: Duration.zero,
);

ComposerAutocompleteController _open() => ComposerAutocompleteController()
  ..setQuery(_query)
  ..setSuggestions(_offers);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('is closed until it has both a query and offers', () {
    final c = ComposerAutocompleteController();
    expect(c.isOpen, isFalse);
    c.setQuery(_query);
    expect(c.isOpen, isFalse);
    c.setSuggestions(_offers);
    expect(c.isOpen, isTrue);
  });

  test('a new query returns to row one and notifies once', () {
    final c = _open()..select(2);
    var notified = 0;
    c.addListener(() => notified++);
    c.setQuery(_query);
    expect(notified, 0);
    c.setQuery(
      const AutocompleteQuery(
        kind: AutocompleteKind.mention,
        term: 'ali',
        start: 6,
        end: 10,
      ),
    );
    expect(c.selected, 0);
    expect(notified, 1);
  });

  group('keys', () {
    test('arrows wrap in both directions', () {
      final c = _open();
      void press(LogicalKeyboardKey k) =>
          c.handleKey(_down(k), onAccept: (_) {});
      press(LogicalKeyboardKey.arrowUp);
      expect(c.selected, 2);
      press(LogicalKeyboardKey.arrowDown);
      expect(c.selected, 0);
      press(LogicalKeyboardKey.arrowDown);
      expect(c.selected, 1);
    });

    test('escape dismisses and is handled', () {
      final c = _open();
      final r = c.handleKey(_down(LogicalKeyboardKey.escape), onAccept: (_) {});
      expect(r, KeyEventResult.handled);
      expect(c.query, isNull);
      expect(c.isOpen, isFalse);
    });

    test('tab and enter accept the current row', () {
      for (final key in [LogicalKeyboardKey.tab, LogicalKeyboardKey.enter]) {
        final c = _open()..select(1);
        AutocompleteSuggestion? got;
        final r = c.handleKey(_down(key), onAccept: (s) => got = s);
        expect(r, KeyEventResult.handled);
        expect(got?.label, 'alan');
      }
    });

    test('other keys are left alone', () {
      final c = _open();
      final r = c.handleKey(
        _down(LogicalKeyboardKey.keyA),
        onAccept: (_) => fail('must not accept'),
      );
      expect(r, KeyEventResult.ignored);
      expect(c.selected, 0);
    });
  });

  group('accept', () {
    test('replaces the trigger span, parks the caret and closes', () {
      final text = TextEditingController(text: 'hello @al');
      final c = _open();
      var focused = false;
      c.accept(
        _offers.first,
        text,
        onGif: () => fail('not a gif'),
        onInserted: () => focused = true,
      );
      expect(text.text, 'hello @alice ');
      expect(text.selection.baseOffset, 'hello @alice '.length);
      expect(focused, isTrue);
      expect(c.query, isNull);
    });

    test('/gif clears the field and hands over instead of inserting', () {
      final text = TextEditingController(text: '/gi');
      final c = ComposerAutocompleteController()
        ..setQuery(
          const AutocompleteQuery(
            kind: AutocompleteKind.command,
            term: 'gi',
            start: 0,
            end: 3,
          ),
        );
      var gif = false;
      c.accept(
        const AutocompleteSuggestion(insert: '/gif ', label: '/gif'),
        text,
        onGif: () => gif = true,
        onInserted: () => fail('no insert'),
      );
      expect(gif, isTrue);
      expect(text.text, isEmpty);
      expect(c.query, isNull);
    });

    test('does nothing with no open query', () {
      final text = TextEditingController(text: 'hi');
      ComposerAutocompleteController().accept(
        _offers.first,
        text,
        onGif: () => fail('no'),
        onInserted: () => fail('no'),
      );
      expect(text.text, 'hi');
    });
  });

  test('dismiss only notifies when something was open', () {
    final c = ComposerAutocompleteController();
    var n = 0;
    c.addListener(() => n++);
    c.dismiss();
    expect(n, 0);
    c.setQuery(_query);
    c.dismiss();
    expect(n, 2);
  });
}
