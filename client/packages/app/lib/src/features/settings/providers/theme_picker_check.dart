// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-line contrast verdict the colour picker shows while a token moves:
/// the worst check that token takes part in, surfaces first, or that it
/// passes them all.
library;

import 'package:flutter/painting.dart' show Color;
import 'package:slimm_design_system/design_system.dart';

class ThemePickerCheck {
  const ThemePickerCheck({required this.passes, required this.text});

  final bool passes;
  final String text;
}

/// The verdict for [token] in [colours], or null when no check involves it.
ThemePickerCheck? themePickerCheck(Map<String, Color> colours, String token) {
  final checks = themeContrastChecks(colours);
  final asText = [
    for (final c in checks)
      if (c.fg == token) c,
  ];
  if (asText.isNotEmpty) return _asText(asText);
  final asSurface = [
    for (final c in checks)
      if (c.bg == token && !c.quieter) c,
  ];
  if (asSurface.isNotEmpty) return _asSurface(asSurface);
  return null;
}

ThemePickerCheck _asText(List<ThemeContrastCheck> checks) {
  final quieter = checks.where((c) => c.quieter).firstOrNull;
  if (quieter != null) {
    return ThemePickerCheck(
      passes: quieter.passes,
      text: quieter.passes
          ? 'Quieter than Secondary text.'
          : 'Needs under ${_ratio(quieter.min)} on base, quieter than '
                'Secondary text. Has ${_ratio(quieter.ratio)}.',
    );
  }
  final onSurfaces = [
    for (final c in checks)
      if (themeSurfaceTokens.contains(c.bg)) c,
  ];
  final surfaceWorst = onSurfaces.isEmpty ? null : _worst(onSurfaces);
  final worst = surfaceWorst != null && !surfaceWorst.passes
      ? surfaceWorst
      : _worst(checks);
  if (worst.passes) {
    return ThemePickerCheck(
      passes: true,
      text: onSurfaces.isNotEmpty
          ? 'Passes on every surface.'
          : 'Passes on ${_surfaceName(worst.bg)}.',
    );
  }
  return ThemePickerCheck(
    passes: false,
    text:
        'Needs ${_ratio(worst.min)} on ${_surfaceName(worst.bg)}. '
        'Has ${_ratio(worst.ratio)}.',
  );
}

ThemePickerCheck _asSurface(List<ThemeContrastCheck> checks) {
  final worst = _worst(checks);
  if (worst.passes) {
    return const ThemePickerCheck(
      passes: true,
      text: 'Every colour on it passes.',
    );
  }
  return ThemePickerCheck(
    passes: false,
    text:
        '${themeTokenLabels[worst.fg]} needs ${_ratio(worst.min)} on it. '
        'Has ${_ratio(worst.ratio)}.',
  );
}

/// The check furthest below its floor, or nearest above it when all pass.
ThemeContrastCheck _worst(List<ThemeContrastCheck> checks) =>
    checks.reduce((a, b) => b.ratio / b.min < a.ratio / a.min ? b : a);

/// Surfaces by their short name ("raised"), other colours by their label.
String _surfaceName(String token) => themeSurfaceTokens.contains(token)
    ? themeTokenLabels[token]!.split(' ').first.toLowerCase()
    : themeTokenLabels[token]!.toLowerCase();

String _ratio(double ratio) => '${ratio.toStringAsFixed(1)}:1';
