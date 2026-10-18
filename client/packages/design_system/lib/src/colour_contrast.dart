// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Colour math for colours people choose themselves: how far one reads
/// against another, and the smallest change that makes it read.
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// The WCAG contrast ratio of [a] against [b], from 1 to 21.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// [color] with its lightness moved just far enough from [surface] to reach
/// [minRatio], keeping its hue and saturation; unchanged when it already does.
Color nudgeForContrast(Color color, Color surface, {double minRatio = 3}) {
  if (contrastRatio(color, surface) >= minRatio) return color;
  final hsl = HSLColor.fromColor(color);
  final towardWhite = surface.computeLuminance() < 0.5;
  var lo = hsl.lightness;
  var hi = towardWhite ? 1.0 : 0.0;
  for (var i = 0; i < 24; i++) {
    final mid = (lo + hi) / 2;
    final passes =
        contrastRatio(hsl.withLightness(mid).toColor(), surface) >= minRatio;
    if (passes) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return hsl.withLightness(hi).toColor().withValues(alpha: color.a);
}

/// The index of the colour in [palette] that looks closest to [color],
/// compared in CIELAB so the match follows the eye rather than raw RGB.
int nearestColourIndex(Color color, List<Color> palette) {
  final target = _lab(color);
  var best = 0;
  var bestDistance = double.infinity;
  for (var i = 0; i < palette.length; i++) {
    final lab = _lab(palette[i]);
    final d = math.pow(lab.$1 - target.$1, 2) +
        math.pow(lab.$2 - target.$2, 2) +
        math.pow(lab.$3 - target.$3, 2);
    if (d < bestDistance) {
      bestDistance = d.toDouble();
      best = i;
    }
  }
  return best;
}

(double, double, double) _lab(Color c) {
  double linear(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  final r = linear(c.r), g = linear(c.g), b = linear(c.b);
  final x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047;
  final y = r * 0.2126 + g * 0.7152 + b * 0.0722;
  final z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883;
  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
  return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)));
}
