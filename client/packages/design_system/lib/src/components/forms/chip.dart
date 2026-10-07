// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small token: `reaction` is a real button carrying an emoji (user content,
/// never interface chrome), a count, and whether the current user is among the
/// people who reacted.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import 'focusable_tap_target.dart';

class AppChip extends StatelessWidget {
  /// A real button: an emoji, a count, and whether the current user reacted.
  const AppChip.reaction({
    super.key,
    required this.emoji,
    required this.count,
    required this.active,
    this.glyph,
    this.onTap,
  });

  /// the emoji glyph. User content, so it is a runtime string
  /// rather than a literal typed into source.
  ///
  /// Not always a codepoint: a deployment's own emoji is keyed by its
  /// `:shortcode:`, which [glyph] then draws in place of this text. It still
  /// names the reaction to a screen reader either way.
  final String? emoji;

  /// drawn instead of [emoji]'s text, for a reaction keyed by
  /// something that has no glyph of its own. The caller sizes it.
  final Widget? glyph;

  /// how many people reacted.
  final int count;

  /// whether the current user is one of them, drawn as an
  /// accent-soft fill plus a heavier weight on the count - never an
  /// outline, which decision 0004 reserves for real focus, and never a
  /// separate marker glyph: the fill and the weight are enough on their
  /// own, the same "no accent border, weight already carries it" shape
  /// [AppSegmentedControl.inline]'s own doc comment already uses.
  final bool active;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    final semanticLabel =
        '${emoji ?? ''} reaction, $count, ${active ? 'you reacted' : 'tap to react'}';

    return FocusableTapTarget(
      onTap: onTap,
      enabled: onTap != null,
      selected: active,
      semanticLabel: semanticLabel,
      ringRadius: AppRadii.full,
      builder: (context, focused, hovered) {
        return Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
          decoration: BoxDecoration(
            color: active ? tokens.accentSoft : tokens.surfaceRaised,
            // Constant regardless of [active]: FocusableTapTarget's own ring is the only one this chip draws.
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.full),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 13px, lineHeight 1: the design's own literal, not on the
              // AppText scale (nearest steps are caption 12 and ui 14).
              glyph ??
                  Text(emoji ?? '',
                      style: const TextStyle(fontSize: 13, height: 1)),
              const SizedBox(width: AppSpacing.s4),
              Text(
                '$count',
                style: AppText.caption.copyWith(
                  color: active ? tokens.accent : tokens.textSecondary,
                  fontWeight: active ? AppWeights.semi : AppWeights.regular,
                  fontFamily: AppFonts.sans,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
