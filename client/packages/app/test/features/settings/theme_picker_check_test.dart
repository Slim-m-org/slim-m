// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picker's live contrast line: the worst check for the colour in hand,
/// or that it passes them all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/theme_picker_check.dart';
import 'package:slimm_design_system/design_system.dart';

Map<String, Color> _dark([Map<String, Color> over = const {}]) => {
  ...ThemeDocument.of(
    AppTokens.dark,
    name: 'x',
    author: '',
    base: 'dark',
    brightness: Brightness.dark,
  ).colours,
  ...over,
};

void main() {
  test('a text colour reports its worst surface', () {
    final colours = _dark({'accent': const Color(0xFF1E6F68)});
    final check = themePickerCheck(colours, 'accent')!;
    expect(check.passes, isFalse);
    final worst = [
      for (final s in ['surfaceSunken', 'surfaceBase', 'surfaceRaised'])
        contrastRatio(colours['accent']!, colours[s]!),
    ].reduce((a, b) => a < b ? a : b);
    expect(
      check.text,
      'Needs 4.5:1 on raised. Has ${worst.toStringAsFixed(1)}:1.',
    );
  });

  test('a passing colour says so', () {
    final check = themePickerCheck(_dark(), 'accent')!;
    expect(check.passes, isTrue);
    expect(check.text, 'Passes on every surface.');
  });

  test('a colour checked on one other colour names it', () {
    final check = themePickerCheck(_dark(), 'accentOn')!;
    expect(check.text, 'Passes on accent fill.');
  });

  test('a surface reports the colour that reads worst on it', () {
    final colours = _dark({'surfaceRaised': const Color(0xFF8A8F96)});
    final check = themePickerCheck(colours, 'surfaceRaised')!;
    expect(check.passes, isFalse);
    final worst = themeContrastChecks(colours)
        .where((c) => c.bg == 'surfaceRaised')
        .reduce((a, b) => b.ratio / b.min < a.ratio / a.min ? b : a);
    expect(
      check.text,
      '${themeTokenLabels[worst.fg]} needs ${worst.min.toStringAsFixed(1)}:1 '
      'on it. Has ${worst.ratio.toStringAsFixed(1)}:1.',
    );
    expect(
      themePickerCheck(_dark(), 'surfaceBase')!.text,
      'Every colour on it passes.',
    );
  });

  test('disabled text must read quieter than secondary text', () {
    final quiet = themePickerCheck(_dark(), 'textDisabled')!;
    expect(quiet.passes, isTrue);
    expect(quiet.text, 'Quieter than Secondary text.');

    final loud = themePickerCheck(
      _dark({'textDisabled': const Color(0xFFFFFFFF)}),
      'textDisabled',
    )!;
    expect(loud.passes, isFalse);
    expect(loud.text, contains('quieter than Secondary text'));
  });

  test('a colour no check reads has no line', () {
    for (final token in [
      'borderSubtle',
      'accentRing',
      'focusRing',
      'dangerBorder',
      'warnSoft',
      'stripe',
    ]) {
      expect(themePickerCheck(_dark(), token), isNull, reason: token);
    }
  });
}
