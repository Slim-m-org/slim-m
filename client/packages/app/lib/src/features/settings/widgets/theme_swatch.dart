// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three-colour strip and the label for each theme in the Theme picker.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart' show AppThemeChoice;

export '../providers/theme_labels.dart'
    show themeLabel, themeBaseOf, themeCopyName;

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

/// Key on the outline, so a test can check it paints over the cells.
/// Foreground, or the cells cover the edge and a swatch the colour of the
/// menu loses its outline.
const themeSwatchOutlineKey = Key('theme_swatch_outline');

class ThemeSwatch extends StatelessWidget {
  const ThemeSwatch({super.key, required this.choice, this.colors});

  final AppThemeChoice choice;

  /// Paints these instead of the choice's own, for a theme read from a file.
  final List<Color>? colors;

  static const _cell = 12.0;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final radius = BorderRadius.circular(AppRadii.control / 2);
    return DecoratedBox(
      key: themeSwatchOutlineKey,
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: tokens.borderStrong),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final color in colors ?? themeSwatchColors(choice))
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
