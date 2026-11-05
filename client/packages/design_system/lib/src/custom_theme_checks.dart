// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The contrast floors of a theme file as data (decision 0106), so the editor
/// can show each one, say what to change and offer the change.
library;

import 'package:flutter/painting.dart';

import 'colour_contrast.dart';
import 'custom_theme.dart';

/// What a token is called where a person reads it.
const themeTokenLabels = <String, String>{
  'surfaceSunken': 'Sunken surface',
  'surfaceBase': 'Base surface',
  'surfaceRaised': 'Raised surface',
  'borderSubtle': 'Subtle border',
  'borderStrong': 'Strong border',
  'textPrimary': 'Primary text',
  'textSecondary': 'Secondary text',
  'textDisabled': 'Disabled text',
  'accent': 'Accent',
  'accentFill': 'Accent fill',
  'accentOn': 'Text on accent',
  'accentSoft': 'Soft accent',
  'accentRing': 'Accent ring',
  'focusRing': 'Focus ring',
  'dangerText': 'Danger text',
  'dangerBorder': 'Danger border',
  'warnText': 'Warning text',
  'warnSoft': 'Warning tint',
  'stripe': 'Row stripe',
};

class ThemeTokenGroup {
  const ThemeTokenGroup(this.title, this.tokens);

  final String title;
  final List<String> tokens;
}

/// The 19 tokens in the order the editor lists them.
const themeTokenGroups = [
  ThemeTokenGroup('Surfaces', [
    'surfaceSunken',
    'surfaceBase',
    'surfaceRaised',
  ]),
  ThemeTokenGroup('Text', ['textPrimary', 'textSecondary', 'textDisabled']),
  ThemeTokenGroup('Accent', [
    'accent',
    'accentFill',
    'accentOn',
    'accentSoft',
    'accentRing',
    'focusRing',
  ]),
  ThemeTokenGroup('Borders', ['borderSubtle', 'borderStrong']),
  ThemeTokenGroup('Status', [
    'dangerText',
    'dangerBorder',
    'warnText',
    'warnSoft',
  ]),
  ThemeTokenGroup('Other', ['stripe']),
];

/// One floor: [fg] must reach [min]:1 on [bg], or, for [quieter], must read
/// less than [min]:1 on [bg].
class ThemeContrastCheck {
  const ThemeContrastCheck({
    required this.fg,
    required this.bg,
    required this.min,
    required this.ratio,
    this.quieter = false,
  });

  final String fg;
  final String bg;
  final double min;
  final double ratio;

  /// The disabled-text rule: a ceiling rather than a floor.
  final bool quieter;

  bool get passes => quieter ? ratio < min : ratio >= min;

  /// The sentence the file parser reports for a failure.
  String get problem => quieter
      ? 'textDisabled must be quieter than textSecondary.'
      : '$fg on $bg is below $min:1.';

  /// The colour for [fg] that would pass this check, or null when it already does.
  Color? fix(Map<String, Color> colours) {
    if (passes) return null;
    final text = colours[fg]!;
    final surface = colours[bg]!;
    if (quieter) return Color.lerp(colours['textSecondary'], surface, 0.5);
    return _nearestPassing(text, surface, min);
  }

  /// A plain instruction for a failing check.
  String hint(Map<String, Color> colours) {
    final label = themeTokenLabels[fg]!;
    final surface = themeTokenLabels[bg]!.toLowerCase();
    if (quieter) {
      return 'Make $label quieter than Secondary text, closer to the background.';
    }
    final fixed = fix(colours);
    final lighter = fixed != null &&
        fixed.computeLuminance() > colours[fg]!.computeLuminance();
    final shown = '${ratio.toStringAsFixed(1)}:1';
    return 'Make $label ${lighter ? 'lighter' : 'darker'}: it needs '
        '${min.toStringAsFixed(1)}:1 on $surface and has $shown.';
  }
}

/// Every floor a theme file must clear, passing or not.
List<ThemeContrastCheck> themeContrastChecks(Map<String, Color> c) {
  ThemeContrastCheck floor(String fg, String bg, double min) =>
      ThemeContrastCheck(
        fg: fg,
        bg: bg,
        min: min,
        ratio: contrastRatio(c[fg]!, c[bg]!),
      );

  return [
    for (final surface in themeSurfaceTokens) ...[
      for (final text in const [
        'textPrimary',
        'textSecondary',
        'accent',
        'dangerText',
        'warnText',
      ])
        floor(text, surface, 4.5),
      floor('borderStrong', surface, 3),
    ],
    floor('accentOn', 'accentFill', 4.5),
    floor('accent', 'accentSoft', 4.5),
    ThemeContrastCheck(
      fg: 'textDisabled',
      bg: 'surfaceBase',
      min: contrastRatio(c['textSecondary']!, c['surfaceBase']!),
      ratio: contrastRatio(c['textDisabled']!, c['surfaceBase']!),
      quieter: true,
    ),
  ];
}

/// [color] with its lightness moved the least that reaches [min]:1 on
/// [surface], going lighter or darker, whichever direction can get there.
Color _nearestPassing(Color color, Color surface, double min) {
  final hsl = HSLColor.fromColor(color);
  Color? best;
  var bestMove = double.infinity;
  for (final end in const [0.0, 1.0]) {
    final reachable = hsl.withLightness(end).toColor();
    if (contrastRatio(reachable, surface) < min) continue;
    var near = hsl.lightness;
    var far = end;
    for (var i = 0; i < 24; i++) {
      final mid = (near + far) / 2;
      if (contrastRatio(hsl.withLightness(mid).toColor(), surface) >= min) {
        far = mid;
      } else {
        near = mid;
      }
    }
    if ((far - hsl.lightness).abs() < bestMove) {
      bestMove = (far - hsl.lightness).abs();
      best = hsl.withLightness(far).toColor();
    }
  }
  if (best != null) return best;
  final white = contrastRatio(const Color(0xFFFFFFFF), surface);
  final black = contrastRatio(const Color(0xFF000000), surface);
  return white >= black ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
}
