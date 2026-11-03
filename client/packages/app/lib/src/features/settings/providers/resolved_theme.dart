// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which tokens and Material mode the theme choice paints with.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart' show AppThemeChoice;

class ResolvedTheme {
  const ResolvedTheme(this.light, this.dark, this.mode);

  final AppTokens light;
  final AppTokens dark;
  final ThemeMode mode;
}

/// A custom or Space default choice whose document is missing paints as System.
ResolvedTheme resolveTheme(
  AppThemeChoice choice, {
  ThemeDocument? custom,
  ThemeDocument? spaceDefault,
}) {
  final document = switch (choice) {
    AppThemeChoice.custom => custom,
    AppThemeChoice.spaceDefault => spaceDefault,
    _ => null,
  };
  if (document != null) {
    final tokens = document.tokens;
    return document.brightness == Brightness.light
        ? ResolvedTheme(tokens, AppTokens.dark, ThemeMode.light)
        : ResolvedTheme(AppTokens.light, tokens, ThemeMode.dark);
  }
  return ResolvedTheme(
    AppTokens.light,
    _darkTokensFor(choice),
    _modeFor(choice),
  );
}

ThemeMode _modeFor(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system ||
  AppThemeChoice.spaceDefault ||
  AppThemeChoice.custom => ThemeMode.system,
  AppThemeChoice.light => ThemeMode.light,
  AppThemeChoice.dark ||
  AppThemeChoice.trueBlack ||
  AppThemeChoice.catppuccin ||
  AppThemeChoice.softDark ||
  AppThemeChoice.forest ||
  AppThemeChoice.halloween => ThemeMode.dark,
};

/// The dark-family choices are palettes, not modes: each is the dark theme
/// built from a different token set, so MaterialApp needs no extra dark slot.
AppTokens _darkTokensFor(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.trueBlack => AppTokens.trueBlack,
  AppThemeChoice.catppuccin => AppTokens.mocha,
  AppThemeChoice.softDark => AppTokens.soft,
  AppThemeChoice.forest => AppTokens.forest,
  AppThemeChoice.halloween => AppTokens.halloween,
  _ => AppTokens.dark,
};
