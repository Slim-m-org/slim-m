// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [alignBoxes]: where each box goes for an align or distribute, and that sizes never change.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

ObjectBox _b(double x, double y, double w, double h) =>
    (x: x, y: y, w: w, h: h);

final _boxes = {
  'a': _b(0, 0, 10, 10),
  'b': _b(50, 30, 20, 20),
  'c': _b(200, 100, 30, 10),
};

void main() {
  test('left, centre and right line up on the group edges', () {
    expect(
        alignBoxes(_boxes, CanvasAlign.left).values.map((b) => b.x), [0, 0, 0]);
    expect(alignBoxes(_boxes, CanvasAlign.right).values.map((b) => b.x + b.w),
        [230, 230, 230]);
    expect(
        alignBoxes(_boxes, CanvasAlign.centre).values.map((b) => b.x + b.w / 2),
        [115, 115, 115]);
  });

  test('top, middle and bottom line up on the group edges', () {
    expect(
        alignBoxes(_boxes, CanvasAlign.top).values.map((b) => b.y), [0, 0, 0]);
    expect(alignBoxes(_boxes, CanvasAlign.bottom).values.map((b) => b.y + b.h),
        [110, 110, 110]);
    expect(
        alignBoxes(_boxes, CanvasAlign.middle).values.map((b) => b.y + b.h / 2),
        [55, 55, 55]);
  });

  test('sizes never change', () {
    final out = alignBoxes(_boxes, CanvasAlign.left);
    expect(out['b']!.w, 20);
    expect(out['c']!.h, 10);
  });

  test(
      'distributing horizontally leaves equal gaps and the ends where they are',
      () {
    final out = alignBoxes(_boxes, CanvasAlign.distributeHorizontally);

    expect(out['a']!.x, 0);
    expect(out['c']!.x, 200);
    final gapAB = out['b']!.x - (out['a']!.x + out['a']!.w);
    final gapBC = out['c']!.x - (out['b']!.x + out['b']!.w);
    expect(gapAB, closeTo(gapBC, 1e-9));
  });

  test('distributing vertically orders by position, not by id', () {
    final out = alignBoxes({
      'z': _b(0, 0, 10, 10),
      'y': _b(0, 300, 10, 10),
      'x': _b(0, 20, 10, 10),
    }, CanvasAlign.distributeVertically);

    expect(out['z']!.y, 0);
    expect(out['y']!.y, 300);
    expect(out['x']!.y, closeTo(150, 1e-9));
  });

  test('distributing fewer than three changes nothing', () {
    final two = {'a': _boxes['a']!, 'b': _boxes['b']!};

    expect(alignBoxes(two, CanvasAlign.distributeHorizontally), two);
  });
}
