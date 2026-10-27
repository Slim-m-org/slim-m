// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tool wheel: a ring of tools around the point a right-click was held on
/// empty canvas. A flick toward a tool and a release picks it; a release
/// without a flick leaves the wheel open to click, Tab or arrow through.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_shape_icons.dart';
import 'canvas_tool_model.dart';

/// What the wheel offers, clockwise from the top, in the tool strip's order.
enum CanvasWheelItem {
  move(CanvasTool.pan, 'Move'),
  pen(CanvasTool.pen, 'Pen'),
  note(CanvasTool.note, 'Note'),
  shape(CanvasTool.shape, 'Shape'),
  eraser(CanvasTool.eraser, 'Eraser'),
  pasteImage(null, 'Paste image');

  const CanvasWheelItem(this.tool, this.label);

  /// Null for an item that acts instead of arming a tool.
  final CanvasTool? tool;
  final String label;

  /// One rule with the tool strip, so the wheel never offers what the strip cannot.
  bool isAvailable({required bool canDraw}) =>
      tool?.isAvailable(canDraw: canDraw) ?? canDraw;
}

/// Distance from the wheel's centre to each tool's centre.
const double canvasWheelRadius = 76;

/// Each tool's diameter; at the touch target floor so a flick need not be exact.
const double canvasWheelItemSize = 44;

/// Room a wheel needs on every side of its centre.
const double canvasWheelExtent =
    canvasWheelRadius + canvasWheelItemSize / 2 + 8;

/// A press must travel this far from the wheel's centre before it names a tool.
const double canvasWheelDeadZone = 24;

/// The tool a pointer at [pointer] points at from [center], or null inside the dead zone.
int? canvasWheelSector({
  required Offset center,
  required Offset pointer,
  int count = 6,
  double deadZone = canvasWheelDeadZone,
}) {
  final delta = pointer - center;
  if (delta.distance < deadZone) return null;
  final step = 2 * math.pi / count;
  var angle = math.atan2(delta.dx, -delta.dy);
  if (angle < 0) angle += 2 * math.pi;
  return ((angle + step / 2) / step).floor() % count;
}

/// Where item [index] sits around [center].
Offset canvasWheelItemCenter(Offset center, int index, {int count = 6}) {
  final angle = 2 * math.pi * index / count;
  return center + Offset(math.sin(angle), -math.cos(angle)) * canvasWheelRadius;
}

/// [anchor] moved so the whole wheel stays inside [bounds] less [padding].
Offset canvasWheelCenter(Offset anchor, Size bounds, EdgeInsets padding) {
  double place(double at, double lo, double hi) =>
      hi <= lo ? (lo + hi) / 2 : at.clamp(lo, hi).toDouble();
  return Offset(
    place(
      anchor.dx,
      padding.left + canvasWheelExtent,
      bounds.width - padding.right - canvasWheelExtent,
    ),
    place(
      anchor.dy,
      padding.top + canvasWheelExtent,
      bounds.height - padding.bottom - canvasWheelExtent,
    ),
  );
}

class CanvasToolWheel extends StatefulWidget {
  const CanvasToolWheel({
    super.key,
    required this.center,
    required this.highlight,
    required this.tool,
    required this.shapeKind,
    required this.canDraw,
    required this.onPick,
    required this.onDismiss,
  });

  /// Overlay-local, already held inside the overlay by [canvasWheelCenter].
  final Offset center;

  /// The item a flick points at; follows the held pointer.
  final ValueListenable<CanvasWheelItem?> highlight;
  final CanvasTool tool;
  final CanvasShapeKind shapeKind;
  final bool canDraw;
  final ValueChanged<CanvasWheelItem> onPick;
  final VoidCallback onDismiss;

  @override
  State<CanvasToolWheel> createState() => _CanvasToolWheelState();
}

class _CanvasToolWheelState extends State<CanvasToolWheel> {
  CanvasWheelItem? _reached;

  IconData _icon(CanvasWheelItem item) => switch (item) {
    CanvasWheelItem.move => AppIcons.pan,
    CanvasWheelItem.pen => AppIcons.pen,
    CanvasWheelItem.note => AppIcons.note,
    CanvasWheelItem.shape => canvasShapeKindIcon(widget.shapeKind),
    CanvasWheelItem.eraser => AppIcons.eraser,
    CanvasWheelItem.pasteImage => AppIcons.clipboardPaste,
  };

  CanvasWheelItem get _firstFocus => CanvasWheelItem.values.firstWhere(
    (item) =>
        item.isAvailable(canDraw: widget.canDraw) && item.tool == widget.tool,
    orElse: () => CanvasWheelItem.move,
  );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    const diameter = 2 * canvasWheelExtent;
    return Positioned.fill(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onDismiss,
        },
        child: Semantics(
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: 'Tool wheel',
          hint: 'Choose a tool. Escape closes it.',
          child: FocusScope(
            autofocus: true,
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onDismiss,
                      onSecondaryTap: widget.onDismiss,
                      excludeFromSemantics: true,
                    ),
                  ),
                  Positioned(
                    left: widget.center.dx - diameter / 2,
                    top: widget.center.dy - diameter / 2,
                    width: diameter,
                    height: diameter,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: tokens.surfaceRaised,
                        shape: BoxShape.circle,
                        border: Border.all(color: tokens.borderSubtle),
                        boxShadow: AppShadows.float,
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          _centreLabel(tokens),
                          for (final item in CanvasWheelItem.values)
                            _positioned(item),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _centreLabel(AppTokens tokens) => IgnorePointer(
    child: ExcludeSemantics(
      child: ValueListenableBuilder<CanvasWheelItem?>(
        valueListenable: widget.highlight,
        builder: (context, flicked, _) => Text(
          (flicked ?? _reached)?.label ?? 'Tools',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ),
    ),
  );

  Widget _positioned(CanvasWheelItem item) {
    final at = canvasWheelItemCenter(Offset.zero, item.index);
    const reach = canvasWheelExtent - canvasWheelItemSize / 2;
    return Align(
      alignment: Alignment(at.dx / reach, at.dy / reach),
      child: FocusTraversalOrder(
        order: NumericFocusOrder(item.index.toDouble()),
        child: _WheelItem(
          item: item,
          icon: _icon(item),
          current: item.tool == widget.tool,
          available: item.isAvailable(canDraw: widget.canDraw),
          autofocus: item == _firstFocus,
          highlight: widget.highlight,
          onReach: (reached) {
            if (_reached == reached) return;
            setState(() => _reached = reached);
          },
          onPick: () => widget.onPick(item),
        ),
      ),
    );
  }
}

class _WheelItem extends StatefulWidget {
  const _WheelItem({
    required this.item,
    required this.icon,
    required this.current,
    required this.available,
    required this.autofocus,
    required this.highlight,
    required this.onReach,
    required this.onPick,
  });

  final CanvasWheelItem item;
  final IconData icon;
  final bool current;
  final bool available;
  final bool autofocus;
  final ValueListenable<CanvasWheelItem?> highlight;
  final ValueChanged<CanvasWheelItem?> onReach;
  final VoidCallback onPick;

  @override
  State<_WheelItem> createState() => _WheelItemState();
}

class _WheelItemState extends State<_WheelItem> {
  bool _hovered = false;
  bool _focused = false;

  void _reach(bool hovered, bool focused) {
    setState(() {
      _hovered = hovered;
      _focused = focused;
    });
    widget.onReach(hovered || focused ? widget.item : null);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final enabled = widget.available;
    return ValueListenableBuilder<CanvasWheelItem?>(
      valueListenable: widget.highlight,
      builder: (context, flicked, _) {
        final lit = enabled && (flicked == widget.item || _hovered);
        return Semantics(
          button: true,
          enabled: enabled,
          selected: widget.current,
          label: widget.item.label,
          child: Tooltip(
            message: enabled ? widget.item.label : "Can't draw right now",
            excludeFromSemantics: true,
            child: FocusableActionDetector(
              enabled: enabled,
              autofocus: widget.autofocus && enabled,
              mouseCursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onShowHoverHighlight: (v) => _reach(v, _focused),
              onShowFocusHighlight: (v) => _reach(_hovered, v),
              actions: {
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    widget.onPick();
                    return null;
                  },
                ),
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: enabled ? widget.onPick : null,
                child: Container(
                  width: canvasWheelItemSize,
                  height: canvasWheelItemSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: lit
                        ? tokens.accentSoft
                        : (widget.current
                              ? tokens.surfaceSunken
                              : Colors.transparent),
                    border: _focused
                        ? Border.all(color: tokens.focusRing, width: 2)
                        : null,
                  ),
                  child: ExcludeSemantics(
                    child: Icon(
                      widget.icon,
                      size: AppSizes.icon20,
                      color: !enabled
                          ? tokens.textDisabled
                          : (widget.current || lit
                                ? tokens.accent
                                : tokens.textPrimary),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
