// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A chosen colour reads against its surface without losing its hue, and a
/// custom colour falls back to the preset it looks most like.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  test('the contrast ratio spans black on white to a colour on itself', () {
    expect(contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
        closeTo(21, 0.01));
    expect(contrastRatio(const Color(0xFF3FA9C9), const Color(0xFF3FA9C9)), 1);
  });

  test('a colour that already reads is left exactly as chosen', () {
    const red = Color(0xFFE0699A);
    expect(nudgeForContrast(red, const Color(0xFF111111)), red);
  });

  for (final (name, color, surface) in [
    ('yellow on light', const Color(0xFFFFE600), const Color(0xFFF7F8FA)),
    ('navy on dark', const Color(0xFF101A40), const Color(0xFF16181C)),
  ]) {
    test('$name is nudged to just reach 3:1 and keeps its hue', () {
      final nudged = nudgeForContrast(color, surface);
      final ratio = contrastRatio(nudged, surface);
      expect(ratio, greaterThanOrEqualTo(3));
      expect(ratio, lessThan(3.2), reason: 'only as far as needed');
      expect(
        HSLColor.fromColor(nudged).hue,
        closeTo(HSLColor.fromColor(color).hue, 1.5),
      );
    });
  }

  test('a custom colour maps to the preset it looks most like', () {
    const presets = AppCanvasColors.cursors;
    expect(nearestColourIndex(presets[2], presets), 2);
    expect(nearestColourIndex(const Color(0xFFE07A2F), presets), 3);
    expect(nearestColourIndex(const Color(0xFF7A55E8), presets), 1);
  });
}
