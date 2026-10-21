// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ctrl/cmd wheel zoom must scale with the wheel delta, not step a fixed
/// amount per event.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Camera _zoomed(Camera camera, double dy) => cameraAfterWheelScroll(
      camera,
      focal: const Offset(100, 100),
      dx: 0,
      dy: dy,
      zoomModifier: true,
      horizontalModifier: false,
    );

void main() {
  const camera = Camera(x: 0, y: 0, zoom: 1);

  test('a zero vertical delta with the zoom modifier does not zoom', () {
    expect(_zoomed(camera, 0).zoom, 1);
  });

  test('a 1px smooth-wheel delta moves zoom far less than a 100px notch', () {
    final small = _zoomed(camera, -1).zoom - 1;
    final notch = _zoomed(camera, -100).zoom - 1;
    expect(small, lessThan(notch / 10));
  });

  test('twenty 1px events do not compound into a full notch-sized jump', () {
    var c = camera;
    for (var i = 0; i < 20; i++) {
      c = _zoomed(c, -1);
    }
    expect(c.zoom, lessThan(1.5));
  });
}
