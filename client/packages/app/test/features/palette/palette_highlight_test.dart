// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `paletteHighlightSpans` must slice the text it was given, never offsets
/// found in a lower-cased copy of it: dart2js lower-cases U+0130 to two code
/// units, so those offsets run past the end of the original string.
library;

import 'package:flutter/painting.dart';
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
}
