// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [presencePaintOrder]: the tile touched most recently paints topmost.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_geometry.dart';

void main() {
  test('the touch order decides, most recently touched last (topmost)', () {
    const first = 'camera:first';
    const later = 'camera:later';
    final z = {first: 1, later: 9};

    final order = presencePaintOrder({first, later}, (key) => z[key]);

    expect(order, [first, later]);
  });
}
