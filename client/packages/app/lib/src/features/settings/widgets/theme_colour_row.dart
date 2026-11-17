// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One theme colour as a full-width row: its chip, name, what it follows, a
/// warning when a check asks to change it, and its hex; a see-through colour's
/// opacity is its slider's to show. Main colours and the phone's groups share it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_colour_chip.dart';

/// The hex a person reads for [token], with the opacity of a see-through token.
String themeColourHex(String token, Color colour) {
  final hex = hexOfColour(colour.withValues(alpha: 1));
  if (!themeAlphaTokens.contains(token)) return hex;
  return '$hex · ${(colour.a * 100).round()}%';
}

class ThemeColourRow extends StatelessWidget {
  const ThemeColourRow({
    super.key,
    required this.token,
    required this.colour,
    required this.label,
    required this.onTap,
    this.description,
    this.linked = false,
    this.failing = false,
    this.open = false,
  });

  final String token;
  final Color colour;
  final String label;
  final String? description;

  /// Marks [description] with a link: the colour follows a main colour.
  final bool linked;
  final bool failing;

  /// Its picker is open under it.
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final hex = hexOfColour(colour.withValues(alpha: 1));
    return AppListRow(
      label: label,
      subtitle: description,
      subtitleIcon: linked ? AppIcons.linkedColour : null,
      semanticLabel: [
        label,
        ?description,
        themeColourHex(token, colour),
        if (failing) 'fails a contrast check',
      ].join(', '),
      selected: open,
      leading: ThemeColourChip(colour: colour),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.s8,
        children: [
          if (failing)
            Icon(
              AppIcons.warning,
              size: AppSizes.icon16,
              color: tokens.warnText,
            ),
          Text(
            hex,
            style: AppText.caption.copyWith(
              fontFamily: AppFonts.mono,
              color: tokens.textSecondary,
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
