// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tone-coded banner for a message the surrounding content cannot make on
/// its own: an expiring invite, background on a setting, a positive highlight.
library;

import 'package:flutter/material.dart';

import '../../app_icons.dart';
import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';

/// The three tones the source `Callout.jsx` defines. There is no `danger`
/// tone here: destructive messaging in this system lives on the control that
/// performs the action (a destructive button, a destructive `AppMenuItem`),
/// not on an inline banner.
enum AppCalloutTone { warn, info, accent }

/// A bordered banner with an optional icon and arbitrary body content.
///
/// Colour by tone:
/// - [AppCalloutTone.warn]: `warnText` ink, `borderSubtle` border, `warnSoft`
///   fill.
/// - [AppCalloutTone.info]: `textSecondary` ink, `borderSubtle` border,
///   transparent fill. Fully neutral on purpose: info is not one of the seven
///   closed accent roles, so it does not reach for the accent.
/// - [AppCalloutTone.accent]: `accent` ink, `accentFill` border, `accentSoft`
///   fill. This *is* one of the seven roles (a positive highlight), so
///   leaning on the accent here is correct rather than an eighth use of it.
///
/// The source leaves the icon entirely to the caller (`icon &&
/// <span>{icon}</span>`, nothing rendered if omitted). This port keeps that
/// override but falls back to a per-tone default when the caller does not
/// supply one, so a tone is never carried by colour alone: warn, info and
/// accent default to a triangle, a circle-i and a sparkle, three distinct
/// shapes.
class AppCallout extends StatelessWidget {
  const AppCallout(
      {super.key,
      this.tone = AppCalloutTone.warn,
      this.icon,
      this.centred = false,
      required this.child});

  final AppCalloutTone tone;
  final IconData? icon;

  /// Centres the icon on the body, for a one-row body taller than its text, such as text beside buttons.
  final bool centred;
  final Widget child;

  IconData _defaultIcon() => switch (tone) {
        AppCalloutTone.warn => AppIcons.warning,
        AppCalloutTone.info => AppIcons.info,
        AppCalloutTone.accent => AppIcons.highlight,
      };

  String _toneLabel() => switch (tone) {
        AppCalloutTone.warn => 'Warning',
        AppCalloutTone.info => 'Info',
        AppCalloutTone.accent => 'Highlight',
      };

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    final Color ink;
    final Color border;
    final Color fill;
    switch (tone) {
      case AppCalloutTone.warn:
        ink = tokens.warnText;
        border = tokens.borderSubtle;
        fill = tokens.warnSoft;
      case AppCalloutTone.info:
        ink = tokens.textSecondary;
        border = tokens.borderSubtle;
        fill = Colors.transparent;
      case AppCalloutTone.accent:
        ink = tokens.accent;
        border = tokens.accentFill;
        fill = tokens.accentSoft;
    }

    return Semantics(
      label: _toneLabel(),
      container: true,
      child: Container(
        // 11/12 are literal in the source (not on the --space-* grid),
        // ported as-is rather than rounded to the nearest spacing step.
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Row(
          crossAxisAlignment:
              centred ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          spacing: AppSpacing.s8,
          children: [
            // `margin-top: 1` in the source: top-aligned rather than centred,
            // nudged 1px to meet the cap height of the first text line.
            Padding(
              padding: EdgeInsets.only(top: centred ? 0 : 1),
              child: Icon(icon ?? _defaultIcon(),
                  size: AppSizes.icon16, color: ink),
            ),
            Expanded(
              child: DefaultTextStyle.merge(
                style: AppText.caption.copyWith(color: ink, height: 1.45),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
