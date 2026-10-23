// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

double _channel(double v) =>
    v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The docked thread pane is `surfaceRaised` with a `borderStrong` left edge
/// over the chat's `surfaceBase`. The fill steps are too small to carry the
/// division alone (and sunken equals base in true black), so the edge has to
/// clear WCAG 1.4.11's 3:1 against both sides in every theme.
void main() {
  final themes = {
    'light': AppTokens.light,
    'dark': AppTokens.dark,
    'trueBlack': AppTokens.trueBlack,
    'mocha': AppTokens.mocha,
    'soft': AppTokens.soft,
    'forest': AppTokens.forest,
  };

  themes.forEach((name, t) {
    test('$name pane edge is a 3:1 boundary against chat and pane', () {
      expect(_contrast(t.borderStrong, t.surfaceBase), greaterThanOrEqualTo(3));
      expect(
        _contrast(t.borderStrong, t.surfaceRaised),
        greaterThanOrEqualTo(3),
      );
    });

    test('$name pane fill differs from the chat fill', () {
      expect(t.surfaceRaised, isNot(t.surfaceBase));
    });
  });
}
