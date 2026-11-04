// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A theme's three colours and, when it has one, a thumbnail of its picture.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart' show AppThemeChoice;
import '../providers/theme_store.dart';
import 'theme_swatch.dart';

/// The swatch, a gap and a thumbnail, so every row's text starts at one edge when any has a picture.
const themePreviewWidth = 36.0 + AppSpacing.s8 + AppSizes.icon32;

/// Just the swatch, for a list where no theme has a picture.
const themeSwatchWidth = 36.0;

/// The three colours a swatch paints for [document].
List<Color> themeStrip(ThemeDocument document) => [
  document.colours['surfaceBase']!,
  document.colours['accent']!,
  document.colours['textPrimary']!,
];

class ThemePreview extends ConsumerWidget {
  const ThemePreview({
    super.key,
    required this.colours,
    this.pictureId,
    this.reserveThumbnail = true,
  });

  final List<Color> colours;
  final String? pictureId;

  /// False when no row beside this one has a picture, so the swatch is all the room it takes.
  final bool reserveThumbnail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final picture = pictureId == null
        ? null
        : ref.watch(spaceThemePictureProvider(pictureId!)).valueOrNull;
    return SizedBox(
      width: reserveThumbnail ? themePreviewWidth : themeSwatchWidth,
      child: Row(
        spacing: AppSpacing.s8,
        children: [
          ThemeSwatch(choice: AppThemeChoice.custom, colors: colours),
          if (pictureId != null)
            DecoratedBox(
              key: const Key('theme-preview-picture'),
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.control / 2),
                border: Border.all(color: tokens.borderStrong),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.control / 2),
                child: SizedBox.square(
                  dimension: AppSizes.icon32,
                  child: picture == null
                      ? ColoredBox(color: tokens.surfaceSunken)
                      : Image.memory(
                          picture,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
