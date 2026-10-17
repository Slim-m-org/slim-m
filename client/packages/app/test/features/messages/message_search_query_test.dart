// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `parseSearchQuery` (`providers/message_search_query.dart`): every
/// recognised operator on its own, several combined, and the edge cases the
/// parser's own doc comment states - an empty operator value passing
/// through as free text, and a query made entirely of operators leaving no
/// free text at all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_search_query.dart';

void main() {
  test('a plain query with no operators is untouched free text', () {
    final parsed = parseSearchQuery('the quick brown fox');
    expect(parsed.text, 'the quick brown fox');
    expect(parsed.from, isNull);
    expect(parsed.inChannel, isNull);
    expect(parsed.has, isNull);
    expect(parsed.afterDate, isNull);
    expect(parsed.beforeDate, isNull);
    expect(parsed.isEmpty, isFalse);
  });

  test('from: is extracted and removed from the free text', () {
    final parsed = parseSearchQuery('roadmap from:nick');
    expect(parsed.text, 'roadmap');
    expect(parsed.from, 'nick');
  });

  test('in: is extracted and removed from the free text', () {
    final parsed = parseSearchQuery('roadmap in:general');
    expect(parsed.text, 'roadmap');
    expect(parsed.inChannel, 'general');
  });

  test('has: is extracted and removed from the free text', () {
    final parsed = parseSearchQuery('photo has:attachment');
    expect(parsed.text, 'photo');
    expect(parsed.has, 'attachment');
  });

  test('a second has: token accumulates, comma-joined, in order given', () {
    final parsed = parseSearchQuery('has:attachment has:link');
    expect(parsed.has, 'attachment,link');
  });

  test('after: and before: are extracted and removed from the free text', () {
    final parsed = parseSearchQuery(
      'meeting after:2024-01-01 before:2024-06-15',
    );
    expect(parsed.text, 'meeting');
    expect(parsed.afterDate, '2024-01-01');
    expect(parsed.beforeDate, '2024-06-15');
  });

  test(
    'every operator combines, and free text may come before or after them',
    () {
      final parsed = parseSearchQuery(
        'from:nick roadmap in:general has:attachment after:2024-01-01 draft before:2024-06-15',
      );
      expect(parsed.text, 'roadmap draft');
      expect(parsed.from, 'nick');
      expect(parsed.inChannel, 'general');
      expect(parsed.has, 'attachment');
      expect(parsed.afterDate, '2024-01-01');
      expect(parsed.beforeDate, '2024-06-15');
    },
  );

  test(
    'a query made entirely of operators leaves no free text, and is not empty',
    () {
      final parsed = parseSearchQuery('from:nick has:attachment');
      expect(parsed.text, isEmpty);
      expect(parsed.isEmpty, isFalse);
    },
  );

  test('a blank or whitespace-only query is empty', () {
    expect(parseSearchQuery('').isEmpty, isTrue);
    expect(parseSearchQuery('   ').isEmpty, isTrue);
    expect(parseSearchQuery('\t\n').isEmpty, isTrue);
  });

  test(
    'an operator prefix with nothing after the colon is not an operator',
    () {
      final parsed = parseSearchQuery('from: in: has: after: before:');
      expect(parsed.text, 'from: in: has: after: before:');
      expect(parsed.from, isNull);
      expect(parsed.inChannel, isNull);
      expect(parsed.has, isNull);
      expect(parsed.afterDate, isNull);
      expect(parsed.beforeDate, isNull);
    },
  );

  test('later operators of the same kind win over earlier ones', () {
    final parsed = parseSearchQuery('from:alice from:bob');
    expect(parsed.from, 'bob');
  });

  test('an unrecognised word: prefix passes through as free text', () {
    final parsed = parseSearchQuery('http://example.com is:unread');
    expect(parsed.text, 'http://example.com is:unread');
  });
}
