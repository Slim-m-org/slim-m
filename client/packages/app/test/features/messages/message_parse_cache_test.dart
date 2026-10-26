// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Parsing a message is paid once per text, not once per rebuild.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_parse_cache.dart';

void main() {
  test('the parser runs once for repeated text and again after an edit', () {
    var calls = 0;
    final cache = ParseCache<String>((text) {
      calls++;
      return text.toUpperCase();
    });

    final first = cache.of('hello');
    final again = cache.of('hello');
    final edited = cache.of('hello world');

    expect(identical(first, again), isTrue);
    expect(edited, 'HELLO WORLD');
    expect(calls, 2);
  });

  test('the least recently used text is evicted past capacity', () {
    var calls = 0;
    final cache = ParseCache<int>((text) => ++calls, capacity: 2);

    cache
      ..of('a')
      ..of('b')
      ..of('a')
      ..of('c');

    expect(cache.length, 2);
    cache.of('a');
    expect(calls, 3, reason: 'a was touched last, so b was the one evicted');
    cache.of('b');
    expect(calls, 4);
  });

  test('the shared parsers return the same tree for the same text', () {
    expect(
      identical(cachedInline('**hi** @bob'), cachedInline('**hi** @bob')),
      isTrue,
    );
    expect(
      identical(
        cachedMessageBlocks('a\n```\nx\n```'),
        cachedMessageBlocks('a\n```\nx\n```'),
      ),
      isTrue,
    );
    expect(
      identical(
        cachedMarkdownBlocks('# t\n- a'),
        cachedMarkdownBlocks('# t\n- a'),
      ),
      isTrue,
    );
  });
}
