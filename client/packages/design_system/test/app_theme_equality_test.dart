// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// MaterialApp's AnimatedTheme cross-fades whenever the theme it is handed
/// differs from the last one, so a theme built from closures (which never
/// compare equal) restarts that animation on every rebuild of the app root.
/// The same goes for a token set that compares by identity: a custom theme or
/// the high-contrast copy is a fresh instance on every rebuild.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

AppStatusColors _freshStatus(AppStatusColors s) {
  final c = s.all;
  return AppStatusColors(online: c[0], away: c[1], dnd: c[2], offline: c[3]);
}

AppCodeColors _freshCode(AppCodeColors s) {
  final c = s.all;
  return AppCodeColors(
    keyword: c[0],
    string: c[1],
    number: c[2],
    comment: c[3],
    punctuation: c[4],
  );
}

AppTokens _rebuilt(String base) => ThemeDocument.of(
      themeBases[base]!,
      name: base,
      author: 'me',
      base: base,
      brightness: base == 'light' ? Brightness.light : Brightness.dark,
    ).tokens;

const _other = Color(0x01020304);

final _eachFieldChanged = <String, AppTokens Function(AppTokens)>{
  'surfaceSunken': (t) => t.copyWith(surfaceSunken: _other),
  'surfaceBase': (t) => t.copyWith(surfaceBase: _other),
  'surfaceRaised': (t) => t.copyWith(surfaceRaised: _other),
  'borderSubtle': (t) => t.copyWith(borderSubtle: _other),
  'borderStrong': (t) => t.copyWith(borderStrong: _other),
  'textPrimary': (t) => t.copyWith(textPrimary: _other),
  'textSecondary': (t) => t.copyWith(textSecondary: _other),
  'textDisabled': (t) => t.copyWith(textDisabled: _other),
  'accent': (t) => t.copyWith(accent: _other),
  'accentFill': (t) => t.copyWith(accentFill: _other),
  'accentOn': (t) => t.copyWith(accentOn: _other),
  'accentSoft': (t) => t.copyWith(accentSoft: _other),
  'accentRing': (t) => t.copyWith(accentRing: _other),
  'focusRing': (t) => t.copyWith(focusRing: _other),
  'status': (t) => t.copyWith(status: AppStatusColors.mocha),
  'dangerText': (t) => t.copyWith(dangerText: _other),
  'dangerBorder': (t) => t.copyWith(dangerBorder: _other),
  'warnText': (t) => t.copyWith(warnText: _other),
  'warnSoft': (t) => t.copyWith(warnSoft: _other),
  'stripe': (t) => t.copyWith(stripe: _other),
  'code': (t) => t.copyWith(code: AppCodeColors.mocha),
  'backdrop': (t) => t.copyWith(backdrop: AppBackdrop.halloweenWebs),
};

void main() {
  for (final (brightness, tokens) in [
    (Brightness.dark, AppTokens.dark),
    (Brightness.light, AppTokens.light),
  ]) {
    test('two builds of the $brightness theme compare equal', () {
      expect(buildTheme(brightness, tokens), buildTheme(brightness, tokens));
    });
  }

  group('token sets compare by value', () {
    test('a copy with nothing changed equals its source', () {
      final copy = AppTokens.dark.copyWith();
      expect(copy, AppTokens.dark);
      expect(copy.hashCode, AppTokens.dark.hashCode);
    });

    test('colour groups built apart compare equal', () {
      final status = _freshStatus(AppStatusColors.dark);
      final code = _freshCode(AppCodeColors.dark);
      expect(status, AppStatusColors.dark);
      expect(status.hashCode, AppStatusColors.dark.hashCode);
      expect(code, AppCodeColors.dark);
      expect(code.hashCode, AppCodeColors.dark.hashCode);
      expect(
        AppTokens.dark.copyWith(status: status, code: code),
        AppTokens.dark,
      );
    });

    for (final entry in _eachFieldChanged.entries) {
      test('${entry.key} takes part in equality', () {
        expect(entry.value(AppTokens.dark), isNot(AppTokens.dark));
      });
    }

    test('a different colour in a group is a different group', () {
      expect(AppStatusColors.dark, isNot(AppStatusColors.soft));
      expect(AppCodeColors.dark, isNot(AppCodeColors.soft));
    });
  });

  group('a rebuilt token set does not make the theme look new', () {
    for (final base in themeBases.keys) {
      test('the $base theme file resolves to an equal theme', () {
        final brightness = base == 'light' ? Brightness.light : Brightness.dark;
        expect(
          buildTheme(brightness, _rebuilt(base)),
          buildTheme(brightness, _rebuilt(base)),
        );
        expect(_rebuilt(base), themeBases[base]);
      });
    }

    test('the high contrast copy resolves to an equal theme', () {
      expect(
        buildTheme(Brightness.dark, applyHighContrast(AppTokens.dark)),
        buildTheme(Brightness.dark, applyHighContrast(AppTokens.dark)),
      );
    });

    test('a changed token set still makes a different theme', () {
      expect(
        buildTheme(Brightness.dark, AppTokens.dark),
        isNot(buildTheme(Brightness.dark, applyHighContrast(AppTokens.dark))),
      );
    });
  });
}
