// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The search grammar (docs/search.md): every key on its own, the values each
/// accepts, quoting, and the request a parsed query becomes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_search_query.dart';
import 'package:slimm_app/src/features/messages/providers/message_search_request.dart';

/// Epoch milliseconds of a local midnight: the searcher's own day, not a UTC one.
int _local(int year, int month, int day) =>
    DateTime(year, month, day).millisecondsSinceEpoch;

List<String> _typed(String raw) => [
  for (final filter in parseSearchQuery(raw).filters) filter.typed,
];

void main() {
  test('plain words are free text, untouched', () {
    final parsed = parseSearchQuery('the quick brown fox');
    expect(parsed.text, 'the quick brown fox');
    expect(parsed.filters, isEmpty);
    expect(parsed.isEmpty, isFalse);
  });

  test('a blank query is empty', () {
    expect(parseSearchQuery('').isEmpty, isTrue);
    expect(parseSearchQuery(' \t\n').isEmpty, isTrue);
  });

  test('people and channels drop their sigil', () {
    expect(_typed('from:@nick mentions:ana in:#general'), [
      'from:nick',
      'mentions:ana',
      'in:general',
    ]);
  });

  test('has: takes each kind, any case, and type: is read as has:', () {
    expect(_typed('has:IMAGE has:video type:file has:poll'), [
      'has:image',
      'has:video',
      'has:file',
      'has:poll',
    ]);
    for (final kind in searchHasKinds) {
      expect(_typed('has:$kind'), ['has:$kind']);
    }
  });

  test('pinned: takes true or false, and yes or no for them', () {
    expect(_typed('pinned:true pinned:no'), ['pinned:true', 'pinned:false']);
  });

  test('dates take real calendar days, during: a month or a year too', () {
    expect(_typed('before:2026-11-19 after:2024-02-29'), [
      'before:2026-11-19',
      'after:2024-02-29',
    ]);
    expect(_typed('during:2026-11 during:2026 during:2026-11-01'), [
      'during:2026-11',
      'during:2026',
      'during:2026-11-01',
    ]);
    expect(_typed('between:2026-11-01..2026-11-19'), [
      'between:2026-11-01..2026-11-19',
    ]);
  });

  test('a value that does not fit its key stays free text', () {
    const raw =
        'has:sticker pinned:maybe before:2023-02-29 during:2026-13 '
        'between:2026-11-19..2026-11-01 from: in:#';
    final parsed = parseSearchQuery(raw);
    expect(parsed.filters, isEmpty);
    expect(parsed.text, raw);
  });

  test('an unknown key and a URL are free text', () {
    final parsed = parseSearchQuery('http://example.com is:unread');
    expect(parsed.text, 'http://example.com is:unread');
    expect(parsed.filters, isEmpty);
  });

  test('a quoted phrase is one word, and a quoted value may hold spaces', () {
    final parsed = parseSearchQuery('"from:nick said" in:"team chat" ok');
    expect(parsed.text, '"from:nick said" ok');
    expect(parsed.filters.single.value, 'team chat');
    expect(parsed.filters.single.typed, 'in:"team chat"');
  });

  test('chips already committed come first, then what the text holds', () {
    final parsed = parseSearchQuery(
      'roadmap has:link',
      filters: const [SearchFilter(SearchKey.from, 'nick')],
    );
    expect(parsed.text, 'roadmap');
    expect(
      [for (final f in parsed.filters) f.typed],
      ['from:nick', 'has:link'],
    );
  });

  test('word spans give each word its offsets, quotes kept whole', () {
    expect(searchWordSpans(' ab  "c d" e'), [
      (start: 1, end: 3),
      (start: 5, end: 10),
      (start: 11, end: 12),
    ]);
  });

  group('the request', () {
    MessageSearchRequest request(String raw) =>
        messageSearchRequest(parseSearchQuery(raw));

    test('the last of a one-value key wins; has: kinds add up once each', () {
      final r = request('from:a from:b has:image has:link has:image');
      expect(r.from, 'b');
      expect(r.has, 'image,link');
    });

    test(
      'before: is exclusive and after: inclusive, as the server reads them',
      () {
        final r = request('after:2026-11-01 before:2026-11-19');
        expect(r.afterMs, _local(2026, 11, 1));
        expect(r.beforeMs, _local(2026, 11, 19));
      },
    );

    test('during: covers its whole day, month or year', () {
      expect(request('during:2026-11-19').beforeMs, _local(2026, 11, 20));
      expect(request('during:2026-12').afterMs, _local(2026, 12, 1));
      expect(request('during:2026-12').beforeMs, _local(2027, 1, 1));
      expect(request('during:2026').beforeMs, _local(2027, 1, 1));
    });

    test('between: includes both of its days', () {
      final r = request('between:2026-02-27..2026-02-28');
      expect(r.afterMs, _local(2026, 2, 27));
      expect(r.beforeMs, _local(2026, 3, 1));
    });

    test('several dates narrow to the window they all allow', () {
      final r = request('during:2026-11 after:2026-11-10 before:2026-12-25');
      expect(r.afterMs, _local(2026, 11, 10));
      expect(r.beforeMs, _local(2026, 12, 1));
    });

    test('an in: typed by name is sent by name, one picked by its id', () {
      expect(request('in:#general').inChannel, 'general');
      final picked = messageSearchRequest(
        parseSearchQuery(
          '',
          filters: const [
            SearchFilter(SearchKey.inChannel, 'general', channelId: 'c1'),
          ],
        ),
      );
      expect(picked.channelId, 'c1');
      expect(picked.inChannel, isNull);
      expect(picked.isEmpty, isFalse);
    });

    test('a bound past the year 9999 is still an instant the server takes', () {
      final r = request('during:9999');
      expect(r.afterMs, _local(9999, 1, 1));
      expect(r.beforeMs, DateTime(10000).millisecondsSinceEpoch);
      expect(request('between:9999-12-30..9999-12-31').beforeMs, isNotNull);
    });

    test('nothing to search by is empty', () {
      expect(request('').isEmpty, isTrue);
      expect(request('pinned:false').pinned, isFalse);
    });
  });
}
