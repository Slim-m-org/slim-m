// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The region that keeps an object's side dots showing: its box plus each dot's reach, outer half included.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _box = Rect.fromLTWH(100, 100, 120, 60);

void main() {
  test('the outer half of a dot, outside the box, keeps the dots', () {
    final below = _box.bottomCenter + const Offset(0, sideDotReachPx - 1);

    expect(_box.contains(below), isFalse, reason: 'baseline: outside the box');
    expect(holdsSideDots(_box, below, zoom: 1), isTrue);
  });

  test('past the reach of every dot, outside the box, lets go', () {
    final away = _box.bottomCenter + const Offset(0, sideDotReachPx + 1);

    expect(holdsSideDots(_box, away, zoom: 1), isFalse);
  });

  test('a corner outside the box is not near a dot', () {
    expect(holdsSideDots(_box, _box.bottomRight + const Offset(4, 4), zoom: 1),
        isFalse);
  });

  test('a finger reaches further than a mouse', () {
    final between = _box.bottomCenter + const Offset(0, sideDotReachPx + 3);

    expect(holdsSideDots(_box, between, zoom: 1), isFalse);
    expect(holdsSideDots(_box, between, zoom: 1, touch: true), isTrue);
  });

  test('the reach is screen pixels, so it shrinks in world units as zoom grows',
      () {
    final world = _box.bottomCenter + const Offset(0, sideDotReachPx / 2 + 1);

    expect(holdsSideDots(_box, world, zoom: 1), isTrue);
    expect(holdsSideDots(_box, world, zoom: 2), isFalse);
  });
}
