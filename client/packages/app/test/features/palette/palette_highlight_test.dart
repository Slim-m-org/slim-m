// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `paletteHighlightSpans` must slice the text it was given, never offsets
/// found in a lower-cased copy of it: dart2js lower-cases U+0130 to two code
/// units, so those offsets run past the end of the original string.
library;

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show WidgetSpan, SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/palette/widgets/palette_highlight.dart';
import 'package:slimm_design_system/design_system.dart';

List<String> _texts(List<InlineSpan> spans) => [
  for (final span in spans) (span as TextSpan).text!,
];

void main() {
  test('a match after a dotted capital I lands on the right characters', () {
    final spans = paletteHighlightSpans('İstanbul güzel', 'güzel');
    expect(_texts(spans), ['İstanbul ', 'güzel']);
    expect((spans[1] as TextSpan).style?.fontWeight, AppWeights.semi);
  });

  test('a match at the very end does not read past the text', () {
    final spans = paletteHighlightSpans('İİİ abc', 'ABC');
    expect(_texts(spans), ['İİİ ', 'abc']);
  });

  test('regex metacharacters in the query match literally', () {
    final spans = paletteHighlightSpans('a.b*c (d)', '.b*');
    expect(_texts(spans), ['a', '.b*', 'c (d)']);
    expect(paletteHighlightSpans('abc', '(').length, 1);
  });

  test('a query longer than the text, or an absent one, bolds nothing', () {
    expect(_texts(paletteHighlightSpans('ab', 'abc')), ['ab']);
    expect(_texts(paletteHighlightSpans('abc', 'x')), ['abc']);
  });

  group('the words of a full-text query', () {
    List<String> bold(List<InlineSpan> spans) => [
      for (final span in spans)
        if (span is TextSpan && span.style?.fontWeight == AppWeights.semi)
          span.text!,
    ];

    test('every word is marked wherever it sits, in any case', () {
      final spans = paletteHighlightWordSpans(
        'Win the ISO, then win',
        'iso WIN',
      );
      expect(bold(spans), ['Win', 'ISO', 'win']);
      expect(_texts(spans).join(), 'Win the ISO, then win');
    });

    test('a query with no words, or none that match, marks nothing', () {
      expect(bold(paletteHighlightWordSpans('abc', '  ')), isEmpty);
      expect(bold(paletteHighlightWordSpans('abc', 'x')), isEmpty);
      expect(_texts(paletteHighlightWordSpans('abc', 'x')), ['abc']);
    });

    test('a short message is kept whole, on one line', () {
      expect(paletteSnippet('one\n two   three', 'two'), 'one two three');
    });

    test('a match far into a long message is brought into view at a word', () {
      final text = '${List.filled(30, 'padding').join(' ')} needle after';
      final snippet = paletteSnippet(text, 'needle');
      expect(snippet, startsWith('\u2026'));
      expect(snippet, contains('needle after'));
      expect(snippet.length, lessThan(text.length ~/ 2));
      expect(snippet.substring(1), isNot(startsWith(' ')));
    });

    test('marking inside spans leaves an emoji image and styles alone', () {
      const style = TextStyle(fontStyle: FontStyle.italic);
      const emoji = WidgetSpan(child: SizedBox());
      final marked = paletteHighlightInline(const [
        TextSpan(text: 'ship it', style: style),
        emoji,
      ], 'ship');

      expect(marked.last, same(emoji));
      final first = marked.first as TextSpan;
      expect(first.style, style);
      expect(bold(first.children!), ['ship']);
      expect(first.toPlainText(), 'ship it');
    });
  });
}
