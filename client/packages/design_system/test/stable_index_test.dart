// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one hash that spreads an id over a palette: avatars, role dots and
/// canvas cursors all pick a slot through it, so changing it reshuffles every
/// person's colour.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  test('is the sum of code units modulo the palette size', () {
    expect(stableIndexFor('ab', 10), 5);
    expect(stableIndexFor('', 6), 0);
    expect(stableIndexFor('abc', 6), (97 + 98 + 99) % 6);
  });

  test('stays inside the palette and is stable per id', () {
    for (final id in ['u1', 'user-0190', 'x' * 500]) {
      final index = stableIndexFor(id, 6);
      expect(index, inInclusiveRange(0, 5));
      expect(stableIndexFor(id, 6), index);
    }
  });

  test('an empty palette maps everything to slot zero', () {
    expect(stableIndexFor('anything', 0), 0);
    expect(stableIndexFor('anything', -3), 0);
  });
}
