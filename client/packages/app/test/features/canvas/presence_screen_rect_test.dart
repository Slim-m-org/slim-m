// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `presenceScreenRect` maps a tile's world rect to where it paints on screen -
/// translate by the camera, then scale by zoom. Every presence bubble's
/// position rides on it, so a swapped operation or an unscaled extent would
/// misplace or missize all of them at once.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_geometry.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  test('translates by the camera and scales the whole rect by zoom', () {
    final screen = presenceScreenRect(
      const Rect.fromLTWH(30, 40, 100, 50),
      const Camera(x: 10, y: 20, zoom: 2),
    );
    // left (30-10)*2, top (40-20)*2, width 100*2, height 50*2.
    expect(screen, const Rect.fromLTWH(40, 40, 200, 100));
  });

  test('is the identity at zoom 1 with the camera at the origin', () {
    const world = Rect.fromLTWH(5, 6, 7, 8);
    expect(presenceScreenRect(world, const Camera()), world);
  });
}
