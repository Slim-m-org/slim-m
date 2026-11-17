// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A square, icon-only control: header actions, toolbar buttons, message-row
/// hover actions.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app_haptics.dart';
import '../../app_metrics.dart';
import '../../app_motion.dart';
import '../../app_tokens.dart';
import '../../press_tracking.dart';
import '../../touch_targets.dart';
import 'control_with_options.dart';
import 'spinner.dart';

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
///
/// Only a button given an [active] value is announced as a toggle; leaving it
/// null keeps a plain action button from reading as a switch that is off.
class AppIconButton extends StatefulWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
    this.variant = AppIconButtonVariant.ghost,
    this.size = AppIconButtonSize.md,
    this.active,
    this.touch,
    this.iconSize = AppSizes.icon20,
    this.tooltip,
    this.excludeTooltipFromSemantics,
    this.focusNode,
    this.suppressOwnHoverFill = false,
    this.busy = false,
  });

  final IconData icon;

  /// Announced by assistive tech. Required: an icon-only control with
  /// nothing to say its own name is unreachable to a screen reader.
  final String semanticLabel;

  final VoidCallback? onPressed;
  final AppIconButtonVariant variant;
  final AppIconButtonSize size;
  final bool? active;

  bool get _active => active ?? false;

  /// Null means "whatever this subtree is at", read from [AppTouchTargets].
  final bool? touch;
  final double iconSize;
  final String? tooltip;

  /// Keeps [tooltip] out of what a screen reader hears, for a label that
  /// already says it. Null keeps it out when it repeats [semanticLabel], and
  /// when it only adds to the label's end the addition becomes the hint.
  final bool? excludeTooltipFromSemantics;

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

  /// Swaps the icon for a spinner and ignores presses, while the control keeps
  /// its focus, so a keyboard user is not dropped when work starts.
  final bool busy;

  @override
  State<AppIconButton> createState() => _AppIconButtonState();
}

class _AppIconButtonState extends State<AppIconButton> with PressTracking {
  bool _hovered = false;
  bool _focused = false;

  final _tooltip = GlobalKey<TooltipState>();

  void _onFocusHighlight(bool focused) {
    setState(() => _focused = focused);
    // A keyboard user has no hover, so focus is when the name appears.
    if (focused) {
      // After the frame: the control focus left dismisses every tooltip as it goes.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && _focused) _tooltip.currentState?.ensureTooltipVisible();
      });
    } else {
      Tooltip.dismissAllToolTips();
    }
  }

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

    final button = _visual(tokens, visualSize, radius, joined, enabled);
    final tooltip = widget.tooltip;
    // A tooltip that adds to the label (a shortcut, a note) is heard as that addition alone, after the name.
    final extended = widget.excludeTooltipFromSemantics == null &&
        tooltip != null &&
        tooltip.length > widget.semanticLabel.length &&
        tooltip.startsWith(widget.semanticLabel);

    Widget control = Semantics(
      label: widget.semanticLabel,
      hint: extended
          ? tooltip.substring(widget.semanticLabel.length).trim()
          : null,
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
          onShowFocusHighlight: _onFocusHighlight,
          actions: _activateActions(enabled),
          child: _gestures(enabled, outerSize, joined, button),
        ),
      ),
    );

    if (tooltip != null) {
      // An included Tooltip's message joins the label in the accessible name, so one the label already says doubled what assistive tech announced; a genuinely different tooltip still reaches it.
      control = Tooltip(
        key: _tooltip,
        message: tooltip,
        showDuration: const Duration(seconds: 3),
        // A held press belongs to the options; hover still shows the tooltip.
        triggerMode:
            joined ? TooltipTriggerMode.manual : TooltipTriggerMode.longPress,
        excludeFromSemantics: widget.excludeTooltipFromSemantics ??
            (extended || widget.semanticLabel.contains(tooltip)),
        child: control,
      );
    }

    return control;
  }

  void _press() {
    if (!widget.busy) widget.onPressed!();
  }

  Map<Type, Action<Intent>> _activateActions(bool enabled) {
    if (!enabled) return const <Type, Action<Intent>>{};
    return <Type, Action<Intent>>{
      ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _press()),
    };
  }

  Widget _gestures(bool enabled, double outerSize, bool joined, Widget button) {
    return GestureDetector(
      // Opaque so the whole hit box responds, not just the visual inside it.
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setPressed(true) : null,
      onTapUp: enabled ? (_) => setPressed(false) : null,
      onTapCancel: enabled ? () => setPressed(false) : null,
      onTap: enabled
          ? () {
              if (widget.busy) return;
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
            scale: pressed ? AppMotion.pressScale : 1,
            duration: AppMotion.reduced(context, AppMotion.fast),
            curve: AppMotion.entrance,
            child: button,
          ),
        ),
      ),
    );
  }

  Widget _visual(
    AppTokens tokens,
    double visualSize,
    BorderRadius radius,
    bool joined,
    bool enabled,
  ) {
    var (ink, fill, border) = _colors(tokens, enabled);

    if (_hovered &&
        enabled &&
        !widget._active &&
        !widget.suppressOwnHoverFill) {
      fill = tokens.surfaceRaised;
    }

    if (widget._active) {
      fill = tokens.accentSoft;
      ink = tokens.accent;
      // The caret beside a joined control draws the seam in the subtle border.
      border = joined ? tokens.borderSubtle : tokens.accentFill;
    }

    // Hover and active arrive on AppListRow's own fast clock, never snapping.
    return AnimatedContainer(
      duration: AppMotion.reduced(context, AppMotion.fast),
      curve: AppMotion.entrance,
      width: visualSize,
      height: visualSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: _border(border, joined),
      ),
      foregroundDecoration: _focused
          ? BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: tokens.focusRing, width: 2),
            )
          : null,
      child: widget.busy
          ? const AppSpinner(size: AppSpinnerSize.sm)
          : Icon(widget.icon, size: widget.iconSize, color: ink),
    );
  }

  (Color, Color, Color?) _colors(AppTokens tokens, bool enabled) {
    return switch (widget.variant) {
      AppIconButtonVariant.ghost => (
          tokens.textSecondary,
          Colors.transparent,
          null,
        ),
      AppIconButtonVariant.danger => (
          tokens.dangerText,
          Colors.transparent,
          tokens.dangerBorder,
        ),
      AppIconButtonVariant.dangerGhost => (
          _hovered && enabled ? tokens.dangerText : tokens.textSecondary,
          Colors.transparent,
          null,
        ),
    };
  }

  static Border? _border(Color? color, bool joined) {
    if (color == null) return null;
    if (!joined) return Border.all(color: color);
    return Border(
      top: BorderSide(color: color),
      left: BorderSide(color: color),
      bottom: BorderSide(color: color),
    );
  }
}
