// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The name each theme choice goes by, shared by the picker and theme exports.
library;

import 'package:slimm_design_system/design_system.dart' show themeNameMaxChars;

import '../../../providers/providers.dart' show AppThemeChoice;

String themeLabel(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system => 'System',
  AppThemeChoice.light => 'Light',
  AppThemeChoice.dark => 'Dark',
  AppThemeChoice.trueBlack => 'True black',
  AppThemeChoice.catppuccin => 'Catppuccin',
  AppThemeChoice.softDark => 'Soft dark',
  AppThemeChoice.forest => 'Forest',
  AppThemeChoice.halloween => 'Halloween',
  AppThemeChoice.spaceDefault => 'Space default',
  AppThemeChoice.custom => 'Custom',
};

/// The built-in preset a choice paints with, or null for a choice that is not one palette.
String? themeBaseOf(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.dark => 'dark',
  AppThemeChoice.light => 'light',
  AppThemeChoice.trueBlack => 'trueBlack',
  AppThemeChoice.catppuccin => 'catppuccin',
  AppThemeChoice.softDark => 'softDark',
  AppThemeChoice.forest => 'forest',
  AppThemeChoice.halloween => 'halloween',
  AppThemeChoice.system ||
  AppThemeChoice.spaceDefault ||
  AppThemeChoice.custom => null,
};

/// The name a copy of [name] starts with, kept inside the 40 character limit.
String themeCopyName(String name) {
  const suffix = ' copy';
  const room = themeNameMaxChars - suffix.length;
  return '${String.fromCharCodes(name.trim().runes.take(room))}$suffix';
}
