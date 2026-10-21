// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The reusable chip every in-call control draws, split out of
/// `voice_call_controls.dart` to keep that file under the review budget once
/// the keyboard-shortcuts and speaker-switch additions pushed it over.
///
/// Public since before this split: `voice_call_dock.dart`'s canvas toggle and
/// `incoming_call_overlay.dart`'s ring/decline pair already draw the
/// identical chip, not only `CallControls`'s own row.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class CallDockButton extends StatelessWidget {
  const CallDockButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onPressed,
    this.destructive = false,
    this.holdOpensOptions = false,
    this.pending = false,
    this.unavailable = false,
    this.level,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final bool destructive;

  /// A held press opens options here, so it must not also show the tooltip.
  final bool holdOpensOptions;

  /// Asked for, not in effect yet. Reads as busy rather than on.
  ///
  /// On iOS a screen share is a request the user answers in a system picker,
  /// and nothing is published until they do. Drawing that as active describes
  /// a share nobody can see.
  final bool pending;
  final VoidCallback onPressed;

  /// The member cannot use this control here; a tap shows [tooltip] instead of calling [onPressed].
  final bool unavailable;

  /// A live input level, 0 to 1, drawn as a 2px bar along the chip's bottom
  /// edge in the ok colour, so "we can hear you" does not rest on colour.
  final double? level;

  @override
  Widget build(BuildContext context) {
    if (!unavailable) return _chip(context, null, onPressed);
    return _ExplainOnTap(builder: _chip);
  }

  Widget _chip(
    BuildContext context,
    GlobalKey<TooltipState>? tooltipKey,
    VoidCallback onTap,
  ) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final joined = AppControlWithOptions.joinedOf(context);
    // Danger is outlined, never filled: unmistakable without being the brightest thing on screen.
    final background = _background(tokens);
    final foreground = _foreground(tokens);
    final border = destructive ? tokens.dangerBorder : tokens.borderSubtle;

    // AppIconButton's own split: a fixed chip, invisible tap area growing to AppSizes.rowTouch at touch density.
    final touch = AppTouchTargets.of(context);
    final hitTarget = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
    const visualSize = AppSizes.controlMd;
    final outerSize = visualSize > hitTarget ? visualSize : hitTarget;

    final radius = joined
        ? const BorderRadius.horizontal(left: Radius.circular(AppRadii.control))
        : BorderRadius.circular(AppRadii.control);

    return _TooltipOnFocus(
      tooltipKey: tooltipKey,
      builder: (key) => Tooltip(
        key: key,
        message: tooltip,
        showDuration: const Duration(seconds: 3),
        // A held press belongs to the options; hover still shows the tooltip.
        triggerMode: joined || holdOpensOptions
            ? TooltipTriggerMode.manual
            : TooltipTriggerMode.longPress,
        child: Semantics(
          button: true,
          enabled: !unavailable,
          label: tooltip,
          child: _chipFocus(
            joined: joined,
            builder: (context, onFocusChange, focused) => InkWell(
              onTap: onTap,
              // The ring is drawn by the chip itself; see AppInsetFocus and AppFocusRing.
              focusColor: Colors.transparent,
              onFocusChange: onFocusChange,
              borderRadius: radius,
              child: SizedBox(
                width: outerSize,
                height: outerSize,
                child: Align(
                  alignment: joined ? Alignment.centerRight : Alignment.center,
                  child: Container(
                    width: visualSize,
                    height: visualSize,
                    foregroundDecoration: joined
                        ? appInsetFocusDecoration(
                            context,
                            focused: focused,
                            borderRadius: radius,
                          )
                        : null,
                    decoration: BoxDecoration(
                      color: background,
                      borderRadius: radius,
                      border: _border(border, joined: joined),
                    ),
                    child: pending
                        ? _spinner(tokens)
                        : _withLevel(
                            Icon(
                              icon,
                              size: AppSizes.icon16,
                              color: foreground,
                            ),
                            tokens,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _background(AppTokens tokens) {
    if (destructive) return Colors.transparent;
    return active ? tokens.accentSoft : tokens.surfaceRaised;
  }

  Color _foreground(AppTokens tokens) {
    if (unavailable) return tokens.textDisabled;
    if (destructive) return tokens.dangerText;
    return active ? tokens.accent : tokens.textSecondary;
  }

  // The caret's left border is the seam, so the joined half has no right border.
  static Border _border(Color color, {required bool joined}) {
    if (!joined) return Border.all(color: color);
    return Border(
      top: BorderSide(color: color),
      left: BorderSide(color: color),
      bottom: BorderSide(color: color),
    );
  }

  Widget _spinner(AppTokens tokens) => Center(
    child: AppSpinner(size: AppSpinnerSize.sm, color: tokens.textSecondary),
  );

  Widget _withLevel(Widget icon, AppTokens tokens) {
    final value = level;
    if (value == null) return icon;
    return Stack(
      children: [
        Center(child: icon),
        Positioned(
          left: AppSpacing.s4,
          right: AppSpacing.s4,
          bottom: 3,
          height: 2,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              key: const ValueKey('call-dock-level'),
              widthFactor: value.clamp(0.0, 1.0),
              heightFactor: 1,
              child: ColoredBox(color: tokens.status.online),
            ),
          ),
        ),
      ],
    );
  }

  /// A lone chip keeps [AppFocusRing]; the leading half of a pair draws its
  /// ring inset so the two halves can touch.
  static Widget _chipFocus({
    required bool joined,
    required Widget Function(BuildContext, ValueChanged<bool>, bool) builder,
  }) {
    if (joined) return AppInsetFocus(builder: builder);
    return AppFocusRing(
      radius: AppRadii.control,
      builder: (context, onFocusChange) =>
          builder(context, onFocusChange, false),
    );
  }
}

/// Owns the tooltip key so a tap on an unavailable chip can open its reason.
class _ExplainOnTap extends StatefulWidget {
  const _ExplainOnTap({required this.builder});

  final Widget Function(BuildContext, GlobalKey<TooltipState>, VoidCallback)
  builder;

  @override
  State<_ExplainOnTap> createState() => _ExplainOnTapState();
}

class _ExplainOnTapState extends State<_ExplainOnTap> {
  final _key = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    _key,
    () => _key.currentState?.ensureTooltipVisible(),
  );
}

/// Shows the chip's tooltip while keyboard focus is on it: a keyboard user has no hover to bring the name up.
class _TooltipOnFocus extends StatefulWidget {
  const _TooltipOnFocus({required this.tooltipKey, required this.builder});

  final GlobalKey<TooltipState>? tooltipKey;
  final Widget Function(GlobalKey<TooltipState> key) builder;

  @override
  State<_TooltipOnFocus> createState() => _TooltipOnFocusState();
}

class _TooltipOnFocusState extends State<_TooltipOnFocus> {
  late final GlobalKey<TooltipState> _key =
      widget.tooltipKey ?? GlobalKey<TooltipState>();

  void _onFocusChange(bool focused) {
    if (focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
      // After the frame: the chip focus left dismisses every tooltip as it goes.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _key.currentState?.ensureTooltipVisible();
      });
    } else if (!focused) {
      Tooltip.dismissAllToolTips();
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: _onFocusChange,
    child: widget.builder(_key),
  );
}
