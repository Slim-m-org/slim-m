// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The title every theme sheet opens with on a phone: a thumbnail, the theme
/// and where it is from, so the sheet names what its items act on.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_miniature_thumb.dart';

class ThemeSheetTitle extends StatelessWidget {
  const ThemeSheetTitle({
    super.key,
    required this.name,
    required this.caption,
    required this.miniature,
  });

  final String name;

  /// Where the theme is from: 'Built in', 'Mine', 'Not saved' or the Space's.
  final String caption;

  /// The bars miniature, or its broken placeholder.
  final Widget miniature;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSheetHeader(
          name,
          caption: caption,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            AppSpacing.s8,
            AppSpacing.s16,
            AppSpacing.s12,
          ),
          leading: ThemeMiniatureThumb(width: 48, child: miniature),
        ),
        ColoredBox(
          color: tokens.borderSubtle,
          child: const SizedBox(height: 1),
        ),
        const SizedBox(height: AppSpacing.s4),
      ],
    );
  }
}
