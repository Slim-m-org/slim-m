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
import '../../touch_targets.dart';
import '../../app_typography.dart';
import 'focusable_tap_target.dart';

class AppSegmentedOption {
  const AppSegmentedOption({
    required this.label,
    this.disabled = false,
    this.disabledReason,
  });

  final String label;

  /// Shown but not choosable, in [AppTokens.textDisabled] and wiring no tap
  /// handler at all.
  ///
  /// Not the same as a caller dropping the callback: that leaves the option
  /// looking available and reports it as a button to assistive tech, so the
  /// only feedback for an unavailable choice is that nothing happens.
  final bool disabled;

  /// Said on hover over a [disabled] option, for the pointer that cannot tap it.
  final String? disabledReason;
}

class AppSegmentedControl extends StatelessWidget {
  const AppSegmentedControl.inline({
    super.key,
    required this.options,
    required this.selectedIndex,
    required this.onSegmentSelected,
    this.semanticLabel,
  })  : fill = false,
        assert(
          options.length >= 2,
          'a segmented control needs at least two options',
        );

  /// Every segment takes a share of the width in proportion to its label of the width it is given, never wrapping, for a control that spans a menu or card.
  const AppSegmentedControl.fill({
    super.key,
    required this.options,
    required this.selectedIndex,
    required this.onSegmentSelected,
    this.semanticLabel,
  })  : fill = true,
        assert(
          options.length >= 2,
          'a segmented control needs at least two options',
        );

  final bool fill;

  /// The trough's padding and border on both sides, so a filled control on touch totals a full touch row.
  static const double _troughInset = 8;

  /// The width an [AppSegmentedControl.inline] takes when nothing wraps it, for a row deciding whether the control fits beside its label.
  static double inlineWidth(
    BuildContext context,
    List<AppSegmentedOption> options,
  ) =>
      _naturalWidth(context, options, AppSpacing.s12);

  static double _naturalWidth(
    BuildContext context,
    List<AppSegmentedOption> options,
    double padding,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    var width = 2 * (3 + 1) + AppSpacing.s4 * (options.length - 1);
    for (final option in options) {
      final painter = TextPainter(
        text: TextSpan(
          text: option.label,
          style: AppText.caption.copyWith(
            fontFamily: AppFonts.sans,
            fontWeight: AppWeights.medium,
          ),
        ),
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      width += painter.width + 2 * padding + 2;
      painter.dispose();
    }
    return width;
  }

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
        child: fill
            ? _filled(context, tokens, AppSpacing.s4)
            : LayoutBuilder(
                builder: (context, box) => _inline(context, tokens, box),
              ),
      ),
    );
  }

  /// The narrowest a segment may get before the row scrolls instead of ellipsizing every label.
  static const double _segmentFloor = 72;

  /// One row, never wrapped: natural widths when they fit, equal shares when the parent fixes the width or the labels only fit tighter, a scroll past that.
  Widget _inline(BuildContext context, AppTokens tokens, BoxConstraints box) {
    final room = box.maxWidth;
    if (!room.isFinite) return _natural(context, tokens);
    final natural = _naturalWidth(context, options, AppSpacing.s12);
    if (natural <= room) {
      return box.hasTightWidth
          ? _filled(context, tokens, AppSpacing.s12)
          : _natural(context, tokens);
    }
    final compact = _naturalWidth(context, options, AppSpacing.s4);
    if (compact <= room || room / options.length >= _segmentFloor) {
      return _filled(context, tokens, AppSpacing.s4);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: _natural(context, tokens),
    );
  }

  Widget _natural(BuildContext context, AppTokens tokens) => Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.s4,
        children: [
          for (var i = 0; i < options.length; i++)
            _inlineSegment(context, tokens, i, AppSpacing.s12, ellipsis: false),
        ],
      );

  Widget _filled(BuildContext context, AppTokens tokens, double padding) => Row(
        spacing: AppSpacing.s4,
        children: [
          for (var i = 0; i < options.length; i++)
            Expanded(
              flex: options[i].label.length + 4,
              child:
                  _inlineSegment(context, tokens, i, padding, ellipsis: true),
            ),
        ],
      );

  Widget _inlineSegment(
    BuildContext context,
    AppTokens tokens,
    int index,
    double padding, {
    required bool ellipsis,
  }) {
    final option = options[index];
    final selected = index == selectedIndex;

    final segment = FocusableTapTarget(
      onTap: option.disabled ? null : () => onSegmentSelected(index),
      enabled: !option.disabled,
      selected: selected,
      semanticLabel: option.label,
      builder: (context, focused, hovered) {
        return AnimatedContainer(
          duration: AppMotion.reduced(
            context,
            const Duration(milliseconds: 150),
          ),
          // minHeight, not height: a wrapped label needs more than one line at a large text scale.
          constraints: BoxConstraints(
            minHeight: fill && AppTouchTargets.of(context)
                ? AppSizes.rowTouch - _troughInset
                : AppSizes.controlSm,
          ),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(
            horizontal: padding,
          ),
          decoration: BoxDecoration(
            color: selected ? tokens.surfaceRaised : Colors.transparent,
            border: Border.all(
              color: selected ? tokens.borderSubtle : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          // A filled segment's tap target already names it.
          child: ExcludeSemantics(
            excluding: fill,
            child: Text(
              option.label,
              textAlign: TextAlign.center,
              maxLines: ellipsis ? 1 : null,
              overflow: ellipsis ? TextOverflow.ellipsis : null,
              style: AppText.caption.copyWith(
                color: switch ((option.disabled, selected)) {
                  (true, _) => tokens.textDisabled,
                  (false, true) => tokens.textPrimary,
                  (false, false) => tokens.textSecondary,
                },
                fontWeight: selected ? AppWeights.medium : AppWeights.regular,
                fontFamily: AppFonts.sans,
                // Grey alone read as merely unselected beside a selected neighbour.
                decoration: option.disabled ? TextDecoration.lineThrough : null,
                decorationColor: tokens.textDisabled,
              ),
            ),
          ),
        );
      },
    );
    final reason = option.disabled ? option.disabledReason : null;
    return reason == null ? segment : Tooltip(message: reason, child: segment);
  }
}
