// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The text button: the one control every screen with a real action reaches
/// for.
///
/// Five variants carry a deliberate hierarchy through weight as well as
/// colour: [AppButtonVariant.primary] is filled and semi-bold on purpose, and
/// the rule that matters is the source design's own: *the only filled button
/// on a screen should be the one real action*. Reaching for a second
/// [AppButtonVariant.primary] to make a secondary action "stand out more" is
/// exactly the mistake this hierarchy exists to prevent; [AppButtonVariant.soft]
/// is the tier for "important but not the one action."
library;

import 'package:flutter/material.dart';

import '../../app_haptics.dart';
import '../../app_metrics.dart';
import '../../app_motion.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import '../../touch_targets.dart';

enum AppButtonVariant { primary, secondary, ghost, soft, danger }

/// `sm`/`lg` (28/40) have no matching [AppSizes] step; `md` lands exactly on
/// [AppSizes.controlMd] (34).
enum AppButtonSize { sm, md, lg }

class _Metrics {
  const _Metrics(
      {required this.height,
      required this.horizontalPadding,
      required this.textStyle});
  final double height;
  final double horizontalPadding;
  final TextStyle textStyle;
}

_Metrics _metricsFor(AppButtonSize size) => switch (size) {
      AppButtonSize.sm => const _Metrics(
          height: 28,
          horizontalPadding: AppSpacing.s12,
          textStyle: AppText.caption,
        ),
      AppButtonSize.md => const _Metrics(
          height: AppSizes.controlMd,
          horizontalPadding: AppSpacing.s16,
          textStyle: AppText.ui,
        ),
      AppButtonSize.lg => const _Metrics(
          height: 40, horizontalPadding: AppSpacing.s20, textStyle: AppText.ui),
    };

class _Look {
  const _Look(
      {required this.background,
      required this.foreground,
      required this.border,
      required this.weight});
  final Color background;
  final Color foreground;
  final Color border;
  final FontWeight weight;
}

_Look _lookFor(AppButtonVariant variant, AppTokens tokens) => switch (variant) {
      AppButtonVariant.primary => _Look(
          background: tokens.accentFill,
          foreground: tokens.accentOn,
          border: tokens.accentFill,
          weight: AppWeights.semi,
        ),
      AppButtonVariant.secondary => _Look(
          background: Colors.transparent,
          foreground: tokens.textPrimary,
          border: tokens.borderSubtle,
          weight: AppWeights.medium,
        ),
      AppButtonVariant.ghost => _Look(
          background: Colors.transparent,
          foreground: tokens.textSecondary,
          border: Colors.transparent,
          weight: AppWeights.regular,
        ),
      AppButtonVariant.soft => _Look(
          background: tokens.accentSoft,
          foreground: tokens.accent,
          border: tokens.accentFill,
          weight: AppWeights.medium,
        ),
      AppButtonVariant.danger => _Look(
          background: Colors.transparent,
          foreground: tokens.dangerText,
          border: tokens.dangerBorder,
          weight: AppWeights.medium,
        ),
    };

/// A labelled, tappable control with an optional leading icon.
///
/// [touch] (matching [AppListRow]'s parameter of the same name) grows the
/// button itself, not an invisible tap box around it, to meet
/// [AppSizes.rowTouch]: unlike [AppIconButton], a text button's whole body is
/// already visible content, so the touch floor should change what is drawn
/// rather than pad around it. Left unset it follows [AppTouchTargets.of].
class AppButton extends StatefulWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = AppButtonVariant.secondary,
    this.size = AppButtonSize.md,
    this.icon,
    this.full = false,
    this.wrapLabel = false,
    this.disabled = false,
    this.busy = false,
    this.touch,
    this.semanticLabel,
    this.focusNode,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final AppButtonSize size;
  final IconData? icon;

  /// Fills the width the parent gives it, for a form's or a sheet's one
  /// full-width action.
  final bool full;

  /// Lets a long label take more lines, growing the button, instead of
  /// ellipsizing; for a text-link action whose words matter at large scale.
  final bool wrapLabel;

  /// Independent of [onPressed], matching the source design: a button keeps
  /// its real handler (a save action a caller re-enables once a form becomes
  /// valid, say) rather than having to null it out and reattach it later.
  final bool disabled;

  /// The label cross-fades to a spinner and taps are ignored, without the
  /// dimming [disabled] gets: a form mid-submit is working, not unavailable.
  /// The fade takes [AppMotion.fast] and collapses to a swap under reduce
  /// motion.
  final bool busy;

  /// Null means "whatever this subtree is at", read from [AppTouchTargets].
  final bool? touch;
  final String? semanticLabel;
  final FocusNode? focusNode;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _focused = false;

  /// The finger-down state a phone has no hover to stand in for; drawn as a
  /// slight scale-down so the press is felt as well as ticked.
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final enabled =
        !widget.disabled && !widget.busy && widget.onPressed != null;
    final metrics = _metricsFor(widget.size);
    final look = _lookFor(widget.variant, tokens);
    final touch = widget.touch ?? AppTouchTargets.of(context);
    final hitTarget = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
    final height = metrics.height > hitTarget ? metrics.height : hitTarget;

    final labelRow = Row(
      key: const ValueKey('label'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: AppSizes.icon16, color: look.foreground),
          const SizedBox(width: AppSpacing.s8),
        ],
        // Flexible so a long label at a large text scale ellipsizes instead of
        // overflowing; with room to spare the intrinsic width is unchanged.
        Flexible(
          child: Text(
            widget.label,
            maxLines: widget.wrapLabel ? null : 1,
            textAlign: TextAlign.center,
            overflow:
                widget.wrapLabel ? TextOverflow.clip : TextOverflow.ellipsis,
            style: metrics.textStyle.copyWith(
                color: look.foreground,
                fontWeight: look.weight,
                height: widget.wrapLabel ? 1.25 : 1),
          ),
        ),
      ],
    );

    final content = AnimatedSwitcher(
      duration: AppMotion.reduced(context, AppMotion.fast),
      child: widget.busy
          ? SizedBox(
              key: const ValueKey('busy'),
              width: AppSizes.icon16,
              height: AppSizes.icon16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: look.foreground,
              ),
            )
          : labelRow,
    );

    final button = Container(
      height: widget.wrapLabel ? null : height,
      constraints: widget.wrapLabel ? BoxConstraints(minHeight: height) : null,
      width: widget.full ? double.infinity : null,
      padding: EdgeInsets.symmetric(
          horizontal: metrics.horizontalPadding,
          vertical: widget.wrapLabel ? AppSpacing.s4 : 0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: look.background,
        border: Border.all(color: look.border),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      foregroundDecoration: _focused
          ? BoxDecoration(
              border: Border.all(color: tokens.focusRing, width: 2),
              borderRadius: BorderRadius.circular(AppRadii.control),
            )
          : null,
      // The label and icon are purely visual: without this their own semantics
      // merge with the explicit label below into a doubled "Save\nSave".
      child: ExcludeSemantics(child: content),
    );

    final control = Semantics(
      label: widget.semanticLabel ?? widget.label,
      button: true,
      enabled: enabled,
      child: Opacity(
        opacity: enabled || widget.busy ? 1 : 0.45,
        child: FocusableActionDetector(
          enabled: enabled,
          focusNode: widget.focusNode,
          mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          actions: !enabled
              ? const <Type, Action<Intent>>{}
              : <Type, Action<Intent>>{
                  ActivateIntent: CallbackAction<ActivateIntent>(
                      onInvoke: (_) => widget.onPressed!()),
                },
          child: GestureDetector(
            onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
            onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
            onTapCancel:
                enabled ? () => setState(() => _pressed = false) : null,
            onTap: enabled
                ? () {
                    AppHaptics.selection();
                    widget.onPressed!();
                  }
                : null,
            child: AnimatedScale(
              scale: _pressed ? AppMotion.pressScale : 1,
              duration: AppMotion.reduced(context, AppMotion.fast),
              curve: AppMotion.entrance,
              child: button,
            ),
          ),
        ),
      ),
    );

    return widget.full ? control : IntrinsicWidth(child: control);
  }
}
