// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A square, icon-only control: header actions, toolbar buttons, message-row
/// hover actions.
library;

import 'package:flutter/material.dart';

import '../../app_haptics.dart';
import '../../app_metrics.dart';
import '../../app_motion.dart';
import '../../app_tokens.dart';
import '../../touch_targets.dart';
import 'control_with_options.dart';

/// `danger` states the consequence at rest, for a destructive action sitting
/// among ordinary ones. `dangerGhost` withholds it until hover, for the case
/// where the button's position already says what it does and a standing red
/// outline would only be noise - a title bar's close button being the one
/// that prompted it.
enum AppIconButtonVariant { ghost, danger, dangerGhost }

/// Visual diameter. `sm`/`touch` land exactly on [AppSizes.controlSm]/
/// [AppSizes.controlLg] (26/38); `md`, the default,
/// is [AppSizes.icon28].
enum AppIconButtonSize { sm, md, touch }

double _diameterFor(AppIconButtonSize size) => switch (size) {
      AppIconButtonSize.sm => AppSizes.controlSm,
      AppIconButtonSize.md => AppSizes.icon28,
      AppIconButtonSize.touch => AppSizes.controlLg,
    };

/// A square icon-only button with rounded corners, not a circle.
///
/// [active] is a persistent accent-tinted state (a toggled-on control, an
/// applied filter): a fill plus an accent border. It is a different thing
/// from keyboard focus, which is a ring drawn from [AppTokens.focusRing] on
/// top of whatever [active]/[variant] state is already showing. Conflating
/// the two would make a toggled-on button indistinguishable from one a
/// keyboard user merely tabbed onto.
///
/// The visible sizes (26/28/34/38) are all smaller than this system's touch
/// minimum. [touch] (matching [AppListRow]'s parameter of the same name)
/// grows the invisible tap area to [AppSizes.rowTouch] without growing the
/// glyph, the same "small control, bigger tap target" split the row height
/// already uses. Left unset it follows [AppTouchTargets.of].
class AppIconButton extends StatefulWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
    this.variant = AppIconButtonVariant.ghost,
    this.size = AppIconButtonSize.md,
    this.active = false,
    this.touch,
    this.iconSize = AppSizes.icon20,
    this.tooltip,
    this.focusNode,
    this.suppressOwnHoverFill = false,
  });

  final IconData icon;

  /// Announced by assistive tech. Required: an icon-only control with
  /// nothing to say its own name is unreachable to a screen reader.
  final String semanticLabel;

  final VoidCallback? onPressed;
  final AppIconButtonVariant variant;
  final AppIconButtonSize size;
  final bool active;

  /// Null means "whatever this subtree is at", read from [AppTouchTargets].
  final bool? touch;
  final double iconSize;
  final String? tooltip;
  final FocusNode? focusNode;

  /// True when an enclosing control already paints its own hover tint that
  /// covers this button (a list row's kebab, say). Left false this button's
  /// own hover fill can sit on top of that enclosing tint at a colour it
  /// never accounted for - a channel row's selection fill, for one, which
  /// this button's plain `surfaceRaised` visibly clashed against on hover.
  /// True keeps the focus ring and press scale, which still read as this
  /// button's own feedback, and drops only the redundant/conflicting colour
  /// change so the enclosing highlight stays the one source of truth for
  /// hover, the same "share one mechanism" call `MessageRow.hoverFillKey`
  /// already made for its own hover fill.
  final bool suppressOwnHoverFill;

  @override
  State<AppIconButton> createState() => _AppIconButtonState();
}

class _AppIconButtonState extends State<AppIconButton> {
  bool _hovered = false;
  bool _focused = false;

  /// Finger-down feedback for a phone, where there is no hover fill to lean
  /// on; a small scale-down that a haptic tick lands alongside.
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final enabled = widget.onPressed != null;
    final visualSize = _diameterFor(widget.size);
    final baseRadius =
        visualSize >= AppSizes.controlMd ? AppRadii.card : AppRadii.control;
    final joined = AppControlWithOptions.joinedOf(context);
    final radius = joined
        ? BorderRadius.horizontal(left: Radius.circular(baseRadius))
        : BorderRadius.circular(baseRadius);
    final touch = widget.touch ?? AppTouchTargets.of(context);
    final hitTarget = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
    final outerSize = visualSize > hitTarget ? visualSize : hitTarget;

    Color ink;
    Color fill;
    Color? border;

    switch (widget.variant) {
      case AppIconButtonVariant.ghost:
        ink = tokens.textSecondary;
        fill = Colors.transparent;
        border = null;
      case AppIconButtonVariant.danger:
        ink = tokens.dangerText;
        fill = Colors.transparent;
        border = tokens.dangerBorder;
      case AppIconButtonVariant.dangerGhost:
        ink = _hovered && enabled ? tokens.dangerText : tokens.textSecondary;
        fill = Colors.transparent;
        border = null;
    }

    if (_hovered && enabled && !widget.active && !widget.suppressOwnHoverFill) {
      fill = tokens.surfaceRaised;
    }

    if (widget.active) {
      fill = tokens.accentSoft;
      ink = tokens.accent;
      // The caret beside a joined control draws the seam in the subtle border.
      border = joined ? tokens.borderSubtle : tokens.accentFill;
    }

    // Hover and active arrive on AppListRow's own fast clock, never snapping.
    final button = AnimatedContainer(
      duration: AppMotion.reduced(context, AppMotion.fast),
      curve: AppMotion.entrance,
      width: visualSize,
      height: visualSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: border == null
            ? null
            : joined
                ? Border(
                    top: BorderSide(color: border),
                    left: BorderSide(color: border),
                    bottom: BorderSide(color: border),
                  )
                : Border.all(color: border),
      ),
      foregroundDecoration: _focused
          ? BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: tokens.focusRing, width: 2),
            )
          : null,
      child: Icon(widget.icon, size: widget.iconSize, color: ink),
    );

    Widget control = Semantics(
      label: widget.semanticLabel,
      button: true,
      enabled: enabled,
      toggled: widget.active,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: FocusableActionDetector(
          enabled: enabled,
          focusNode: widget.focusNode,
          mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onShowHoverHighlight: (v) => setState(() => _hovered = v),
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          actions: !enabled
              ? const <Type, Action<Intent>>{}
              : <Type, Action<Intent>>{
                  ActivateIntent: CallbackAction<ActivateIntent>(
                      onInvoke: (_) => widget.onPressed!()),
                },
          child: GestureDetector(
            // Opaque so the whole hit box responds, not just the visual inside it.
            behavior: HitTestBehavior.opaque,
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
            child: SizedBox(
              width: outerSize,
              height: outerSize,
              child: Align(
                alignment: joined ? Alignment.centerRight : Alignment.center,
                child: AnimatedScale(
                  scale: _pressed ? AppMotion.pressScale : 1,
                  duration: AppMotion.reduced(context, AppMotion.fast),
                  curve: AppMotion.entrance,
                  child: button,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      // An included Tooltip's message joins the label in the accessible name, so a tooltip that only repeats the label doubled up what assistive tech announced; excluded only in that case, a genuinely different tooltip still reaches it.
      control = Tooltip(
        message: widget.tooltip!,
        // A held press belongs to the options; hover still shows the tooltip.
        triggerMode:
            joined ? TooltipTriggerMode.manual : TooltipTriggerMode.longPress,
        excludeFromSemantics: widget.tooltip == widget.semanticLabel,
        child: control,
      );
    }

    return control;
  }
}
