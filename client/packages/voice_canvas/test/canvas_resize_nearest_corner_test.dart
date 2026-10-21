// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small box has overlapping handle circles; the nearest corner must win.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  test('touch on the bottom-right of a small box grabs bottom-right', () {
    const box = (x: 100.0, y: 100.0, w: 41.0, h: 26.0);
    final corner = hitTestResizeHandle(
      box,
      const Offset(141, 118),
      1,
      hitRadius: touchResizeHandleHitRadius,
    );
    expect(corner, ResizeCorner.bottomRight);
  });
}
