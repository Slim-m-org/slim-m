// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The contrast floors as data: what fails, what the hint says, and that
/// following the fix passes the same file checks the server runs.
library;

import 'dart:ui' show Brightness, Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Map<String, Color> _coloursOf(String base) => ThemeDocument.of(
      themeBases[base]!,
      name: base,
      author: '',
      base: base,
      brightness: Brightness.dark,
    ).colours;

void main() {
  test('every token has a label and sits in exactly one group', () {
    final grouped = [for (final g in themeTokenGroups) ...g.tokens];
    expect(grouped.toSet(), themeTokenKeys.toSet());
    expect(grouped.length, themeTokenKeys.length);
    expect(themeTokenLabels.keys.toSet(), themeTokenKeys.toSet());
  });

  for (final base in themeBases.keys) {
    test('the built-in $base theme passes every check', () {
      final checks = themeContrastChecks(_coloursOf(base));
      expect([
        for (final c in checks)
          if (!c.passes) c.problem
      ], isEmpty);
    });
  }

  test('a faint primary text fails on all three surfaces with a hint', () {
    final colours = {
      ..._coloursOf('dark'),
      'textPrimary': themeBases['dark']!.surfaceBase,
    };
    final failing = [
      for (final c in themeContrastChecks(colours))
        if (!c.passes) c,
    ];
    expect(
      failing.map((c) => '${c.fg} on ${c.bg}'),
      containsAll([
        'textPrimary on surfaceSunken',
        'textPrimary on surfaceBase',
        'textPrimary on surfaceRaised',
      ]),
    );
    final base = failing.firstWhere((c) => c.bg == 'surfaceBase');
    expect(base.problem, 'textPrimary on surfaceBase is below 4.5:1.');
    expect(base.hint(colours), contains('Make Primary text lighter'));
    expect(base.hint(colours), contains('4.5:1 on base surface'));
  });

  test('a fix passes the check it was made for', () {
    final colours = {
      ..._coloursOf('dark'),
      'accentOn': themeBases['dark']!.accentFill,
    };
    final check = themeContrastChecks(colours).firstWhere(
      (c) => c.fg == 'accentOn' && !c.passes,
    );
    final fixed = check.fix(colours)!;
    final next = {...colours, 'accentOn': fixed};
    final again = themeContrastChecks(next)
        .firstWhere((c) => c.fg == 'accentOn' && c.bg == 'accentFill');
    expect(again.passes, isTrue);
  });

  test('a passing check offers no fix', () {
    final colours = _coloursOf('dark');
    for (final check in themeContrastChecks(colours)) {
      expect(check.fix(colours), isNull, reason: check.problem);
    }
  });

  test('disabled text louder than secondary fails and the fix quiets it', () {
    final colours = {
      ..._coloursOf('dark'),
      'textDisabled': themeBases['dark']!.textPrimary,
    };
    final check = themeContrastChecks(colours).firstWhere((c) => c.quieter);
    expect(check.passes, isFalse);
    expect(check.problem, 'textDisabled must be quieter than textSecondary.');
    expect(check.hint(colours), contains('quieter than Secondary text'));
    final next = {...colours, 'textDisabled': check.fix(colours)!};
    expect(
        themeContrastChecks(next).firstWhere((c) => c.quieter).passes, isTrue);
  });

  test('the parser reports the same sentences the checks do', () {
    final colours = {
      ..._coloursOf('dark'),
      'textPrimary': themeBases['dark']!.surfaceBase,
    };
    final document = ThemeDocument.of(
      themeBases['dark']!,
      name: 'x',
      author: '',
      base: 'dark',
      brightness: Brightness.dark,
    ).copyWith(colours: colours);
    final parsed = parseThemeFile(document.toJsonText());
    expect(parsed.problems,
        contains('textPrimary on surfaceBase is below 4.5:1.'));
  });

  test('copyWith changes only what it is given', () {
    final document = ThemeDocument.of(
      themeBases['forest']!,
      name: 'Pine',
      author: 'Ren',
      base: 'forest',
      brightness: Brightness.dark,
      picture: const ThemePicture(dim: 0.5, vignette: true, blur: 0.1),
    );
    final renamed = document.copyWith(name: 'Fir');
    expect(renamed.name, 'Fir');
    expect(renamed.author, 'Ren');
    expect(renamed.picture, isNotNull);
    expect(document.copyWith(dropPicture: true).picture, isNull);
  });
}
