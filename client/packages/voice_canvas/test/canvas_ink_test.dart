// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  const named = {'blue': Color(0xFF0000FF)};
  const ink = Color(0xFF112233);

  test('a named key resolves from the map, and wins over a hex reading', () {
    expect(resolveCanvasInk(named, 'blue', ink), const Color(0xFF0000FF));
  });

  test('a #rrggbb string is any colour, in either case', () {
    expect(resolveCanvasInk(named, '#ff8800', ink), const Color(0xFFFF8800));
    expect(resolveCanvasInk(named, '#FF8800', ink), const Color(0xFFFF8800));
  });

  test('anything else falls back to the ink', () {
    for (final bad in ['#12345', '#1234567', '#gg0000', 'ff8800', '', 'nope']) {
      expect(resolveCanvasInk(named, bad, ink), ink, reason: bad);
    }
    expect(resolveCanvasInk(named, null, ink), ink);
  });

  test('canvasHexOf round-trips through the parser', () {
    const colour = Color(0xFF3A7BD5);
    expect(canvasHexOf(colour), '#3a7bd5');
    expect(parseCanvasHexColor(canvasHexOf(colour)), colour);
  });

  test('the cache stays bounded and still answers after it resets', () {
    for (var i = 0; i < 700; i++) {
      final hex = '#${i.toRadixString(16).padLeft(6, '0')}';
      expect(parseCanvasHexColor(hex), Color(0xFF000000 | i));
    }
    expect(parseCanvasHexColor('#000001'), const Color(0xFF000001));
  });
}
