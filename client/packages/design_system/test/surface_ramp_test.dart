// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The surface ramp: whether sunken, base and raised actually read as three
/// surfaces, measured rather than eyeballed.
///
/// ## Why OKLab lightness and not WCAG contrast
///
/// `contrast_test.dart` is the right tool for ink on a surface and the wrong
/// one for two adjacent surfaces. WCAG contrast is a ratio of relative
/// luminance, which is close to linear light, so at the dark end a large
/// perceptual step barely moves the ratio and at the light end a small one
/// moves it a lot. Measured on the shipped tokens, dark's sunken-to-base step
/// is 1.038:1 and light's is 1.065:1, which suggests light's is 70% bigger;
/// in OKLab lightness they are 1.77 and 2.15, a 21% difference. Gating the
/// ratio would therefore gate the wrong quantity, so this file uses a
/// perceptual lightness axis and leaves WCAG to the file that needs it.
///
/// ## The invariant
///
/// The three surfaces are a ramp with two steps in it. Neither step may be
/// under half the other. That is a shape claim about the ramp rather than a
/// threshold picked to fit the current hexes: a lower step half the size of
/// the upper one stops reading as a third surface and collapses into base,
/// which is the pane bleeding that `surface.sunken` was added to stop (see
/// `docs/decisions/0004-visual-identity-review.md`, "One more surface").
///
/// Dark failed this before 2026-07-27 at 1.77 against 3.80, a ratio of 0.47,
/// while light has always been even at 2.15 against 2.13. It was one token:
/// `surfaceSunken` moved from `#131518` to `#0F1113`.
///
/// ## Why true black is exempt
///
/// It sets sunken equal to base on purpose, and says so in its own doc: with
/// everything collapsing toward `#000000` the rails stop being surfaces and
/// become regions defined only by their edges, which is why its hairline is
/// the brightest of the three themes. Exempting it by an explicit equality
/// check rather than by omitting it from the map means the day someone gives
/// it a distinct sunken value, it starts being gated.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

double _linear(int v) {
  final c = v / 255.0;
  if (c <= 0.04045) return c / 12.92;
  return math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

/// OKLab lightness, 0 to 100. Only the L axis is needed: these tokens are one
/// cool-slate hue at different lightnesses, so a full colour difference would
/// report the same thing with more arithmetic.
double _lightness(Color color) {
  final argb = color.toARGB32();
  final r = _linear((argb >> 16) & 0xFF);
  final g = _linear((argb >> 8) & 0xFF);
  final b = _linear(argb & 0xFF);

  final l =
      math.pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1 / 3);
  final m =
      math.pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1 / 3);
  final s =
      math.pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1 / 3);

  return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s) * 100;
}

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
    test('$name surface ramp has three surfaces, not two', () {
      final sunken = _lightness(t.surfaceSunken);
      final base = _lightness(t.surfaceBase);
      final raised = _lightness(t.surfaceRaised);

      final lower = base - sunken;
      final upper = raised - base;

      // ignore: avoid_print
      print('$name ramp: sunken->base ${lower.toStringAsFixed(2)}, '
          'base->raised ${upper.toStringAsFixed(2)} (OKLab L)');

      expect(upper, greaterThan(0), reason: '$name raised must sit above base');

      // True black collapses sunken into base on purpose. See the library doc.
      if (t.surfaceSunken == t.surfaceBase) {
        expect(name, 'trueBlack',
            reason: 'only trueBlack may collapse sunken into base');
        return;
      }

      expect(lower, greaterThan(0), reason: '$name sunken must sit below base');
      expect(lower, greaterThanOrEqualTo(upper / 2),
          reason: '$name sunken->base is under half of base->raised, so the '
              'rails collapse into base and sunken buys nothing');
      expect(upper, greaterThanOrEqualTo(lower / 2),
          reason: '$name base->raised is under half of sunken->base');
    });
  });
}
