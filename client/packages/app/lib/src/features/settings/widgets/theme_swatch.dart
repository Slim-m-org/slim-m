// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three-colour strip and the label for each theme in the Theme picker.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

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
};

/// The palette a choice paints with; System shows both of its halves.
List<Color> themeSwatchColors(AppThemeChoice choice) {
  if (choice == AppThemeChoice.system) {
    return [
      AppTokens.light.surfaceBase,
      AppTokens.dark.surfaceBase,
      AppTokens.dark.accent,
    ];
  }
  final tokens = switch (choice) {
    AppThemeChoice.light => AppTokens.light,
    AppThemeChoice.trueBlack => AppTokens.trueBlack,
    AppThemeChoice.catppuccin => AppTokens.mocha,
    AppThemeChoice.softDark => AppTokens.soft,
    AppThemeChoice.forest => AppTokens.forest,
    AppThemeChoice.halloween => AppTokens.halloween,
    _ => AppTokens.dark,
  };
  return [tokens.surfaceBase, tokens.accent, tokens.textPrimary];
}

class ThemeSwatch extends StatelessWidget {
  const ThemeSwatch({super.key, required this.choice});

  final AppThemeChoice choice;

  static const _cell = 12.0;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.control / 2),
        border: Border.all(color: tokens.borderStrong, width: 0.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.control / 2 - 0.5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final color in themeSwatchColors(choice))
              SizedBox.square(
                dimension: _cell,
                child: ColoredBox(color: color),
              ),
          ],
        ),
      ),
    );
  }
}
