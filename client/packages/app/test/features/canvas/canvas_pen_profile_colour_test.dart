// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A profile colour picks the pen colour that reads as the same colour, and a
/// grey one keeps the default rather than an arbitrary hue.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_pen_style.dart';

void main() {
  test('each pen colour maps to itself', () {
    for (final pen in canvasPenColors) {
      expect(nearestPenColorKey(pen.color), pen.key, reason: pen.label);
    }
  });

  test('a custom colour picks the nearest hue', () {
    expect(nearestPenColorKey(const Color(0xFF2F6FE0)), 'blue');
    expect(nearestPenColorKey(const Color(0xFF39B36A)), 'green');
  });

  test('a grey, black or white profile colour keeps the default pen', () {
    expect(
      nearestPenColorKey(const Color(0xFF808080)),
      canvasDefaultPenColorKey,
    );
    expect(
      nearestPenColorKey(const Color(0xFF050505)),
      canvasDefaultPenColorKey,
    );
    expect(
      nearestPenColorKey(const Color(0xFFF8F8F8)),
      canvasDefaultPenColorKey,
    );
  });
}
