// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The five tool buttons in decision 0047's order. The selected pen or shape
/// gains a caret (and a long-press) for its options, through the same
/// controls-with-options pattern the call dock's share button uses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart';
import '../providers/canvas_pen_style.dart';
import '../widgets/canvas_custom_colours.dart';
import 'canvas_shape_icons.dart';
import 'canvas_tool_model.dart';
import 'canvas_tool_options.dart';

const _cannotDrawTooltip = "Can't draw right now";

class CanvasToolButtons extends ConsumerWidget {
  const CanvasToolButtons({
    super.key,
    required this.tool,
    required this.onToolChanged,
    required this.canDraw,
    required this.shapeKind,
    required this.onShapeKindChanged,
    required this.pen,
    required this.onPenChanged,
  });

  final CanvasTool tool;
  final ValueChanged<CanvasTool> onToolChanged;
  final bool canDraw;
  final CanvasShapeKind shapeKind;
  final ValueChanged<CanvasShapeKind> onShapeKindChanged;
  final CanvasPenStyle pen;
  final ValueChanged<CanvasPenStyle> onPenChanged;

  /// A second press on the armed tool puts it down, like every other dock toggle.
  void _pick(CanvasTool picked) =>
      onToolChanged(tool == picked ? CanvasTool.pan : picked);

  /// Options belong to the selected tool only, and only while it can be used.
  List<ControlOptionEntry> _optionsFor(
    BuildContext context,
    WidgetRef ref,
    CanvasTool forTool,
  ) {
    if (tool != forTool || !forTool.isAvailable(canDraw: canDraw)) {
      return const [];
    }
    // The picker leads the list canvasCustomColourSwatches returns; the rest are recent picks.
    final custom = forTool == CanvasTool.pen
        ? canvasCustomColourSwatches(
            context: context,
            ref: ref,
            selectedKey: pen.colorKey,
            onChoose: (hex) => onPenChanged(pen.copyWith(colorKey: hex)),
          )
        : const <ControlSwatch>[];
    return canvasToolOptions(
      forTool,
      pen: pen,
      onPenChanged: onPenChanged,
      shapeKind: shapeKind,
      onShapeKindChanged: onShapeKindChanged,
      customPicker: custom.firstOrNull,
      recentColours: custom.skip(1).toList(),
    );
  }

  /// The caret only exists once the tool is selected, so the hint says what is true now.
  String get _shapeHint {
    final armed = 'Shape (S) · ${canvasShapeKindLabel(shapeKind)} armed, ';
    return tool == CanvasTool.shape
        ? '${armed}change it from the caret beside the tool'
        : '${armed}select it to choose another';
  }

  Widget _withOptions(
    BuildContext context,
    WidgetRef ref,
    CanvasTool forTool,
    String label,
    Widget child,
  ) => ControlOptionsMenu(
    active: true,
    menuWidth: _toolMenuWidth,
    caretHeight: AppSizes.icon28,
    opensAbove: true,
    optionsLabel: label,
    options: _optionsFor(context, ref, forTool),
    child: child,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Six touch-sized tools plus the armed caret only fit a 360dp dock when they touch.
    final gap = SizedBox(
      width: AppTouchTargets.of(context) ? 0 : AppSpacing.s4,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIconButton(
          icon: AppIcons.pan,
          semanticLabel: 'Pan',
          tooltip:
              'Pan (H) · pan the canvas, move an object, or select a stroke '
              'to reorder it · hold Shift while resizing to flip '
              'the aspect lock',
          active: tool == CanvasTool.pan,
          onPressed: () => onToolChanged(CanvasTool.pan),
        ),
        gap,
        _withOptions(
          context,
          ref,
          CanvasTool.pen,
          'Pen options',
          _PenButton(
            pen: pen,
            active: tool == CanvasTool.pen,
            canDraw: canDraw,
            onPressed: CanvasTool.pen.isAvailable(canDraw: canDraw)
                ? () => _pick(CanvasTool.pen)
                : null,
          ),
        ),
        gap,
        AppIconButton(
          icon: AppIcons.note,
          semanticLabel: 'Note',
          tooltip: canDraw ? 'Note (N)' : _cannotDrawTooltip,
          active: tool == CanvasTool.note,
          onPressed: CanvasTool.note.isAvailable(canDraw: canDraw)
              ? () => _pick(CanvasTool.note)
              : null,
        ),
        gap,
        AppIconButton(
          icon: AppIcons.textBox,
          semanticLabel: 'Text',
          tooltip: canDraw ? 'Text (T)' : _cannotDrawTooltip,
          active: tool == CanvasTool.text,
          onPressed: CanvasTool.text.isAvailable(canDraw: canDraw)
              ? () => _pick(CanvasTool.text)
              : null,
        ),
        gap,
        _withOptions(
          context,
          ref,
          CanvasTool.shape,
          'Shape options',
          AppIconButton(
            // The armed kind's own glyph, not a generic one - state must be visible, not just remembered.
            icon: canvasShapeKindIcon(shapeKind),
            semanticLabel: 'Shape',
            tooltip: canDraw ? _shapeHint : _cannotDrawTooltip,
            active: tool == CanvasTool.shape,
            onPressed: CanvasTool.shape.isAvailable(canDraw: canDraw)
                ? () => _pick(CanvasTool.shape)
                : null,
          ),
        ),
        gap,
        AppIconButton(
          icon: AppIcons.eraser,
          semanticLabel: 'Eraser',
          tooltip:
              'Eraser (E) · erases ink and shapes. Right-click or long-press a '
              'note or image, then Delete',
          active: tool == CanvasTool.eraser,
          onPressed: () => _pick(CanvasTool.eraser),
        ),
      ],
    );
  }
}

/// Room for the six pen colours and the picker at the 30dp pointer target.
const double _toolMenuWidth = 240;

/// The pen button, with a bar of the armed colour under the glyph, like the tip of the nib.
class _PenButton extends StatelessWidget {
  const _PenButton({
    required this.pen,
    required this.active,
    required this.canDraw,
    required this.onPressed,
  });

  final CanvasPenStyle pen;
  final bool active;
  final bool canDraw;
  final VoidCallback? onPressed;

  /// Drops the bar to just under the 20px glyph, whatever the button's own height.
  static const double _barOffset = 19;
  static const double _barLength = 14;

  /// Grows with the armed width, so the bar still says thin or thick.
  double get _barThickness => (pen.width / 2).clamp(2, 4).toDouble();

  @override
  Widget build(BuildContext context) {
    final outline = penBarOutline(pen.color);
    // Joined to its caret the glyph's box sits right in the hit box, so the bar follows it there.
    final joined = AppControlWithOptions.joinedOf(context);
    return Stack(
      children: [
        AppIconButton(
          icon: AppIcons.pen,
          semanticLabel: 'Pen',
          tooltip: canDraw ? 'Pen (P)' : _cannotDrawTooltip,
          active: active,
          onPressed: onPressed,
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: Align(
              alignment: joined ? Alignment.centerRight : Alignment.center,
              child: SizedBox.square(
                dimension: AppSizes.icon28,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.only(top: _barOffset),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: outline == null
                            ? null
                            : Border.all(color: outline, width: 0.75),
                        borderRadius: BorderRadius.circular(_barThickness),
                      ),
                      child: Container(
                        key: const ValueKey('pen-colour-bar'),
                        width: _barLength,
                        height: _barThickness,
                        decoration: BoxDecoration(
                          color: pen.color,
                          borderRadius: BorderRadius.circular(_barThickness),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A hairline for a near-black or near-white pen, which would vanish into the dark or light surface.
@visibleForTesting
Color? penBarOutline(Color colour) {
  final luminance = colour.computeLuminance();
  if (luminance < 0.05) return const Color(0x99FFFFFF);
  if (luminance > 0.85) return const Color(0x99000000);
  return null;
}
