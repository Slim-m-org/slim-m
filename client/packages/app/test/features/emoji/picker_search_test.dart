// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `pickerResults` searches the catalog case-insensitively: the catalog's own
/// names carry capitals ("flag: Germany", "OK hand") that a lower-cased query
/// would otherwise never match.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_catalog.dart';

List<String> _names(String query) => [
  for (final result in pickerResults(
    query: query,
    category: EmojiCategory.smileysEmotion,
    recent: const [],
    custom: const [],
  ))
    result.label,
];

void main() {
  test('a country name finds its flag', () {
    expect(_names('germany'), contains('flag: Germany'));
    expect(_names('japan'), contains('flag: Japan'));
  });

  test('the query matches whatever case it is typed in', () {
    expect(_names('GERMANY'), contains('flag: Germany'));
    expect(_names('Germany'), contains('flag: Germany'));
  });

  test('a capitalised name matches its lower-cased query', () {
    expect(_names('ok hand'), contains('OK hand'));
  });

  test('a capitalised keyword matches a lower-cased query', () {
    expect(_names('ufo'), contains('flying saucer'));
    expect(_names('christmas'), contains('Santa Claus'));
  });

  test('a short name still matches', () {
    expect(_names('flag_de'), contains('flag: Germany'));
  });

  test('a query nothing answers to finds nothing', () {
    expect(_names('zzzzqqqq'), isEmpty);
  });
}
