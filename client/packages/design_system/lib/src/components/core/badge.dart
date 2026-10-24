// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small label chip: a member role, a bot tag, or a stale-ness warning.
///
/// All three are outlined and unfilled, each with its own letter-spacing
/// (0.06/0.08/0.05em for role/tag/warn). [AppBadgeVariant.role] is not
/// per-role-coloured: the source design styles it from the accent, the same
/// for every role, so a caller cannot recolour it per role even though real
/// role data usually carries one. Ported as specified rather than "improved"
/// with a colour parameter the design does not have.
///
/// The source design sets role/tag/warn at a literal 10px, a step the six-size
/// type scale (11/12/14/15/20/24) does not have; [AppText.micro] (11px) is the
/// nearest and is used for all three rather than a one-off.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';

/// The module variants are for chips a module draws: never uppercased and
/// always led by an origin marker, so none can pass for a role, tag or warn.
enum AppBadgeVariant { role, tag, warn, module, moduleAccent, moduleMuted }

class AppBadge extends StatelessWidget {
  const AppBadge(
      {super.key,
      required this.variant,
      required this.label,
      this.icon,
      this.markerIcon,
      this.semanticLabel});

  final AppBadgeVariant variant;
  final String label;

  /// A small leading glyph, gapped from the label. Optional in every
  /// variant.
  final IconData? icon;

  /// The origin marker the module variants lead with, at the smallest size.
  final IconData? markerIcon;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    // One size for all three variants, not the source's literal 10px, which
    // the type scale has no step for. See the library doc at the top of the
    // file.
    final fontSize = AppText.micro.fontSize!;

    final Color foreground;
    final Color border;
    final String text;
    var letterSpacing = 0.0;
    var tabularNumerals = false;

    switch (variant) {
      case AppBadgeVariant.role:
        foreground = tokens.accent;
        border = tokens.accentFill;
        text = label.toUpperCase();
        letterSpacing = fontSize * 0.06;
      case AppBadgeVariant.tag:
        foreground = tokens.textSecondary;
        border = tokens.borderSubtle;
        text = label.toUpperCase();
        letterSpacing = fontSize * 0.08;
      case AppBadgeVariant.warn:
        foreground = tokens.warnText;
        border = tokens.warnText;
        text = label.toUpperCase();
        letterSpacing = fontSize * 0.05;
        tabularNumerals = true;
      case AppBadgeVariant.module:
        foreground = tokens.textSecondary;
        border = tokens.textSecondary;
        text = label;
      case AppBadgeVariant.moduleAccent:
        foreground = tokens.accent;
        border = tokens.accent;
        text = label;
      case AppBadgeVariant.moduleMuted:
        foreground = tokens.textSecondary;
        border = tokens.borderSubtle;
        text = label;
    }

    final textStyle = TextStyle(
      fontFamily: AppFonts.sans,
      fontSize: fontSize,
      fontWeight: AppWeights.semi,
      color: foreground,
      letterSpacing: letterSpacing,
      fontFeatures:
          tabularNumerals ? const [FontFeature.tabularFigures()] : null,
    );

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (markerIcon != null) ...[
          Icon(markerIcon, size: AppSizes.icon12, color: foreground),
          const SizedBox(width: AppSpacing.s4),
        ],
        if (icon != null) ...[
          Icon(icon, size: AppSizes.icon16, color: foreground),
          const SizedBox(width: AppSpacing.s4),
        ],
        // Flexible, not a bare Text: a caller squeezing this beside other content down to a sliver (a permission row's label column, sharing space with a "you can't grant this" hint) must not overflow.
        Flexible(
          child: Text(text, style: textStyle, overflow: TextOverflow.ellipsis),
        ),
      ],
    );

    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: child,
    );

    // Without ExcludeSemantics, the inner Text's own auto-generated label
    // merges with the explicit one below into a doubled announcement.
    return Semantics(
      // `label`, not `text`: three variants uppercase their display string,
      // and many screen readers read an all-caps word letter by letter.
      label: semanticLabel ?? label,
      container: true,
      child: ExcludeSemantics(child: badge),
    );
  }
}
