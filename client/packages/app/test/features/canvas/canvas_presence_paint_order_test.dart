// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [presencePaintOrder] must put a sent-to-back tile beneath a front one even
/// when the back tile has the higher touch-order z (it was dragged last). A
/// `sentToBack`-blind sort let a back tile's own controls paint over a front
/// tile - the tile-vs-tile overlap the pixel depth test does not reach, since
/// controls only show on hover.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_geometry.dart';

void main() {
  test('a sent-to-back tile paints beneath a front tile even with a higher '
      'touch-order z', () {
    const back = 'camera:back';
    const front = 'camera:front';
    // Back was dragged last (higher z); a sentToBack-blind sort paints it last.
    final z = {back: 5, front: 1};
    final back_ = {back: true, front: false};

    final order = presencePaintOrder(
      {back, front},
      (key) => z[key],
      (key) => back_[key]!,
    );

    // Earlier in the list paints first, i.e. behind.
    expect(order.indexOf(back), lessThan(order.indexOf(front)));
  });

  test('within one depth group the touch order still decides, most recently '
      'touched last (topmost)', () {
    const first = 'camera:first';
    const later = 'camera:later';
    final z = {first: 1, later: 9};

    final order = presencePaintOrder(
      {first, later},
      (key) => z[key],
      (_) => false,
    );

    expect(order, [first, later]);
  });
}
