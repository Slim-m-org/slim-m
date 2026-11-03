// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The name each theme choice goes by, shared by the picker and theme exports.
library;

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
