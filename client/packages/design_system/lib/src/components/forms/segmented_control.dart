// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A row of 2-4 mutually exclusive options: a sunken trough where the selected
/// segment becomes a raised chip with a hairline and medium weight. Its
/// selection is deliberately not accent-coloured: a raised surface plus a
/// border plus weight already satisfies the not-colour-alone requirement
/// without needing the accent at all.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_motion.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import 'focusable_tap_target.dart';

class AppSegmentedOption {
  const AppSegmentedOption({
    required this.label,
    this.disabled = false,
  });

  final String label;

  /// Shown but not choosable, in [AppTokens.textDisabled] and wiring no tap
  /// handler at all.
  ///
  /// Not the same as a caller dropping the callback: that leaves the option
  /// looking available and reports it as a button to assistive tech, so the
  /// only feedback for an unavailable choice is that nothing happens.
  final bool disabled;
}

class AppSegmentedControl extends StatelessWidget {
  const AppSegmentedControl.inline({
    super.key,
    required this.options,
    required this.selectedIndex,
    required this.onSegmentSelected,
    this.semanticLabel,
  }) : assert(options.length >= 2,
            'a segmented control needs at least two options');

  final List<AppSegmentedOption> options;
  final int selectedIndex;
  final ValueChanged<int> onSegmentSelected;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Semantics(
      label: semanticLabel,
      container: true,
      child: Container(
        // 3px trough padding is the design's own literal; AppSpacing has no
        // step between nothing and s4.
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: tokens.surfaceSunken,
          border: Border.all(color: tokens.borderSubtle),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < options.length; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.s4),
              // Flexible so a segment can shrink and wrap its label rather than overflow the row.
              Flexible(child: _inlineSegment(context, tokens, i)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _inlineSegment(BuildContext context, AppTokens tokens, int index) {
    final option = options[index];
    final selected = index == selectedIndex;

    return FocusableTapTarget(
      onTap: option.disabled ? null : () => onSegmentSelected(index),
      enabled: !option.disabled,
      selected: selected,
      semanticLabel: option.label,
      builder: (context, focused, hovered) {
        return AnimatedContainer(
          duration:
              AppMotion.reduced(context, const Duration(milliseconds: 150)),
          // minHeight, not height: a wrapped label needs more than one line at a large text scale.
          constraints: const BoxConstraints(minHeight: AppSizes.controlSm),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s12),
          decoration: BoxDecoration(
            color: selected ? tokens.surfaceRaised : Colors.transparent,
            border: Border.all(
                color: selected ? tokens.borderSubtle : Colors.transparent),
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: Text(
            option.label,
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(
              color: switch ((option.disabled, selected)) {
                (true, _) => tokens.textDisabled,
                (false, true) => tokens.textPrimary,
                (false, false) => tokens.textSecondary,
              },
              fontWeight: selected ? AppWeights.medium : AppWeights.regular,
              fontFamily: AppFonts.sans,
            ),
          ),
        );
      },
    );
  }
}
