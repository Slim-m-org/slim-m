// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every case here is something somebody actually types, and the ones that
/// must *not* trigger matter more than the ones that must: an autocomplete
/// that opens over the message you are writing is worse than none at all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_query.dart';

/// Convenience: the caret at the end of what has been typed so far, which is
/// where it is in almost every real case.
AutocompleteQuery? at(String text) => autocompleteQueryAt(text, text.length);

void main() {
  group('emoji', () {
    test('opens after two characters, not one', () {
      expect(at(':')?.kind, isNull);
      expect(
        at(':s')?.kind,
        isNull,
        reason: 'one character still matches most of the catalog',
      );
      expect(at(':sh')?.kind, AutocompleteKind.emoji);
      expect(at(':sh')?.term, 'sh');
    });

    test('a clock time is not an emoji', () {
      expect(at('meet at 12:30'), isNull);
      expect(at('12:30'), isNull);
    });

    test('a completed shortcode is finished', () {
      expect(
        at(':shrug:'),
        isNull,
        reason:
            'offering completions for a closed shortcode is just in the way',
      );
    });

    test('a smiley is not a search', () {
      expect(at('nice :)'), isNull);
    });

    test('mid-word colons do not trigger', () {
      expect(at('note:this'), isNull);
      expect(at('http://host'), isNull);
    });

    test('lowercases the term but keeps the span', () {
      final q = at('hello :SHR')!;
      expect(q.term, 'shr');
      expect(q.start, 6);
      expect(q.end, 10);
    });
  });

  group('mention', () {
    test('opens immediately, with an empty term', () {
      final q = at('@')!;
      expect(q.kind, AutocompleteKind.mention);
      expect(q.term, '');
    });

    test('an email address is not a mention', () {
      expect(at('nick@example.com'), isNull);
    });

    test('works mid-message after a space', () {
      final q = at('are you off @pri')!;
      expect(q.kind, AutocompleteKind.mention);
      expect(q.term, 'pri');
      expect(q.start, 12);
    });

    test('a space closes it', () {
      expect(at('@priya are you'), isNull);
    });
  });

  group('command', () {
    test('only at the very start of the message', () {
      expect(at('/sh')?.kind, AutocompleteKind.command);
      expect(
        at('yes /sh'),
        isNull,
        reason: 'a slash command is the whole message or it is not one',
      );
    });

    test('paths and and/or are left alone', () {
      expect(at('read /etc/hosts'), isNull);
      expect(at('and/or'), isNull);
    });

    test('a bare slash offers the whole list', () {
      final q = at('/')!;
      expect(q.kind, AutocompleteKind.command);
      expect(q.term, '');
      expect(q.start, 0);
      expect(q.end, 1);
    });
  });

  group('the caret, not the end of the text', () {
    test('reads the trigger the caret is inside, not a later one', () {
      const text = 'hi @pri and :shr';
      // Caret just after "@pri".
      final q = autocompleteQueryAt(text, 7)!;
      expect(q.kind, AutocompleteKind.mention);
      expect(q.term, 'pri');
    });

    test('a caret before any trigger finds nothing', () {
      expect(autocompleteQueryAt('hi @priya', 2), isNull);
    });

    test('out-of-range carets are refused rather than throwing', () {
      expect(autocompleteQueryAt('hi', -1), isNull);
      expect(autocompleteQueryAt('hi', 99), isNull);
    });
  });

  test('an empty composer offers nothing', () {
    expect(at(''), isNull);
  });

  test('a newline resets the scan, so a trigger on line two still works', () {
    final q = at('first line\n@pri')!;
    expect(q.kind, AutocompleteKind.mention);
    expect(q.term, 'pri');
  });

  test('a command on line two is not a command', () {
    expect(
      at('first line\n/sh'),
      isNull,
      reason: 'offset zero, not start-of-line: the message begins once',
    );
  });
}
