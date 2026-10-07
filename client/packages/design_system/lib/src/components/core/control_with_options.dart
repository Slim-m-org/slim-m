// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A control whose plain press stays its primary action, with a small caret
/// beside it that opens the options, but only while there are options.
library;

import 'package:flutter/material.dart';

import '../../app_haptics.dart';
import '../../app_icons.dart';
import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../touch_targets.dart';
import '../forms/focus_ring.dart';

/// Wraps [child] (the primary control, which keeps its own press handling)
/// and, when [onOpenOptions] is set, adds a caret after it and a long-press
/// over the whole control that open the same options.
///
/// This widget presents nothing: [onOpenOptions] opens whatever menu or sheet
/// the caller owns, so the layout-class split between an anchored menu and a
/// bottom sheet stays in one place (`docs/design/desktop-vs-mobile.md`
/// rule 2). A null [onOpenOptions] returns [child] untouched: no caret, no
/// long-press, no extra width, so a control with one thing to do looks and
/// behaves exactly as it did before adopting this.
///
/// The long-press carries [AppHaptics.selection] because a hold has no
/// pointer feedback of its own on a phone (law 3: every hover affordance has
/// a long-press equivalent). The caret is a separate tab stop with its own
/// [optionsLabel], and keeps the full hit target of a control at the current
/// density so adding it never makes either half harder to hit.
class AppControlWithOptions extends StatelessWidget {
  const AppControlWithOptions({
    super.key,
    required this.child,
    required this.onOpenOptions,
    required this.optionsLabel,
    this.active = false,
    this.touch,
    this.visualHeight = AppSizes.controlMd,
  });

  final Widget child;

  /// Null when there is nothing to offer beyond the primary action.
  final VoidCallback? onOpenOptions;

  /// Names the caret to assistive tech and in its tooltip, e.g. "Screen
  /// share options".
  final String optionsLabel;

  /// Tints the caret to match an [active] primary control beside it.
  final bool active;

  /// Null means "whatever this subtree is at", read from [AppTouchTargets].
  final bool? touch;

  /// The caret's drawn height, to match a primary that is not a full chip.
  final double visualHeight;

  /// True inside an [AppControlWithOptions] that is showing its caret.
  ///
  /// The primary reads this to draw as the leading half of one surface: outer
  /// corners rounded, inner (right) edge square and borderless, and its visual
  /// flush with the right edge of its hit box so the two halves touch while
  /// both hit boxes keep their full size.
  static bool joinedOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_JoinedScope>() != null;

  @override
  Widget build(BuildContext context) {
    final open = onOpenOptions;
    if (open == null) return child;
    return _JoinedScope(
      child: GestureDetector(
        onLongPress: () {
          AppHaptics.selection();
          open();
        },
        onSecondaryTapUp: (_) => open(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            child,
            _OptionsCaret(
              label: optionsLabel,
              active: active,
              touch: touch ?? AppTouchTargets.of(context),
              visualHeight: visualHeight,
              onPressed: () {
                AppHaptics.selection();
                open();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Tells the primary control it is the leading half of a joined pair.
class _JoinedScope extends InheritedWidget {
  const _JoinedScope({required super.child});

  @override
  bool updateShouldNotify(_JoinedScope oldWidget) => false;
}

const _caretRadius = BorderRadius.horizontal(
  right: Radius.circular(AppRadii.control),
);

class _OptionsCaret extends StatelessWidget {
  const _OptionsCaret({
    required this.label,
    required this.active,
    required this.touch,
    required this.onPressed,
    required this.visualHeight,
  });

  final String label;
  final bool active;
  final bool touch;
  final VoidCallback onPressed;
  final double visualHeight;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final hit = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
    final outerHeight = visualHeight > hit ? visualHeight : hit;

    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: label,
        child: AppInsetFocus(
          builder: (context, onFocusChange, focused) => InkWell(
            onTap: onPressed,
            focusColor: Colors.transparent,
            onFocusChange: onFocusChange,
            borderRadius: _caretRadius,
            child: SizedBox(
              width: hit,
              height: outerHeight,
              // Flush left so the caret reads as part of the control; the rest of the hit box is slack that spaces it from its neighbour.
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: AppSizes.icon28,
                  height: visualHeight,
                  // The left border is the hairline seam between the halves.
                  decoration: BoxDecoration(
                    color: active ? tokens.accentSoft : tokens.surfaceRaised,
                    borderRadius: _caretRadius,
                    border: Border.all(color: tokens.borderSubtle),
                  ),
                  foregroundDecoration: appInsetFocusDecoration(
                    context,
                    focused: focused,
                    borderRadius: _caretRadius,
                  ),
                  child: Icon(
                    AppIcons.chevronDown,
                    size: AppSizes.icon16,
                    color: active ? tokens.accent : tokens.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
