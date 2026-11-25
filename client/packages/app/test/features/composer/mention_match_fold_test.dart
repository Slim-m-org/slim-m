// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every accented letter the mention search folds lands on its own ASCII letter.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/mention_match.dart';

const _expected = {
  'a': 'àáâãäåāăą',
  'c': 'çćč',
  'd': 'ďđ',
  'e': 'èéêëēėęě',
  'g': 'ğ',
  'i': 'ìíîïīįı',
  'l': 'ł',
  'n': 'ñńň',
  'o': 'òóôõöøōő',
  'r': 'ř',
  's': 'śşšș',
  't': 'ťț',
  'u': 'ùúûüūůűų',
  'y': 'ýÿ',
  'z': 'źżž',
};

void main() {
  for (final MapEntry(key: ascii, value: accented) in _expected.entries) {
    for (final ch in accented.split('')) {
      test('$ch folds to $ascii', () => expect(foldForMatch(ch), ascii));
    }
  }

  test('ligatures expand and capitals fold', () {
    expect(foldForMatch('Straße'), 'strasse');
    expect(foldForMatch('Æon Œuvre'), 'aeon oeuvre');
    expect(foldForMatch('JOSÉ ŘEHOŘ'), 'jose rehor');
  });
}
