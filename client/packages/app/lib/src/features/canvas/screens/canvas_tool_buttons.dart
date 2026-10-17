// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The five tool buttons in decision 0047's order. The selected pen or shape
/// gains a caret (and a long-press) for its options, through the same
/// controls-with-options pattern the call dock's share button uses.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart';
import 'canvas_pen_style.dart';
import 'canvas_shape_icons.dart';
import 'canvas_tool_model.dart';
import 'canvas_tool_options.dart';

class CanvasToolButtons extends StatelessWidget {
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

  /// Options belong to the selected tool only, and only while it can be used.
  List<ControlOptionEntry> _optionsFor(CanvasTool forTool) =>
      tool == forTool && forTool.isAvailable(canDraw: canDraw)
      ? canvasToolOptions(
          forTool,
          pen: pen,
          onPenChanged: onPenChanged,
          shapeKind: shapeKind,
          onShapeKindChanged: onShapeKindChanged,
        )
      : const [];

  /// The caret only exists once the tool is selected, so the hint says what is true now.
  String get _shapeHint {
    final armed = 'Shape · ${canvasShapeKindLabel(shapeKind)} armed, ';
    return tool == CanvasTool.shape
        ? '${armed}change it from the caret beside the tool'
        : '${armed}select it to choose another';
  }

  Widget _withOptions(CanvasTool forTool, String label, Widget child) =>
      ControlOptionsMenu(
        active: true,
        caretHeight: AppSizes.icon28,
        opensAbove: true,
        optionsLabel: label,
        options: _optionsFor(forTool),
        child: child,
      );

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      AppIconButton(
        icon: AppIcons.pan,
        semanticLabel: 'Pan',
        tooltip:
            'Pan the canvas, move an object, or select a stroke '
            'to reorder it · hold Shift while resizing to free '
            'the aspect ratio',
        active: tool == CanvasTool.pan,
        onPressed: () => onToolChanged(CanvasTool.pan),
      ),
      const SizedBox(width: AppSpacing.s4),
      _withOptions(
        CanvasTool.pen,
        'Pen options',
        AppIconButton(
          icon: AppIcons.pen,
          semanticLabel: 'Pen',
          tooltip: canDraw ? 'Pen' : "Can't draw right now",
          active: tool == CanvasTool.pen,
          onPressed: CanvasTool.pen.isAvailable(canDraw: canDraw)
              ? () => onToolChanged(CanvasTool.pen)
              : null,
        ),
      ),
      const SizedBox(width: AppSpacing.s4),
      AppIconButton(
        icon: AppIcons.note,
        semanticLabel: 'Note',
        tooltip: canDraw ? 'Note' : "Can't draw right now",
        active: tool == CanvasTool.note,
        onPressed: CanvasTool.note.isAvailable(canDraw: canDraw)
            ? () => onToolChanged(CanvasTool.note)
            : null,
      ),
      const SizedBox(width: AppSpacing.s4),
      _withOptions(
        CanvasTool.shape,
        'Shape options',
        AppIconButton(
          // The armed kind's own glyph, not a generic one - state must be visible, not just remembered.
          icon: canvasShapeKindIcon(shapeKind),
          semanticLabel: 'Shape',
          tooltip: canDraw ? _shapeHint : "Can't draw right now",
          active: tool == CanvasTool.shape,
          onPressed: CanvasTool.shape.isAvailable(canDraw: canDraw)
              ? () => onToolChanged(CanvasTool.shape)
              : null,
        ),
      ),
      const SizedBox(width: AppSpacing.s4),
      AppIconButton(
        icon: AppIcons.eraser,
        semanticLabel: 'Eraser',
        tooltip:
            'Eraser · pen ink only, select then Delete for a '
            'note, shape or image',
        active: tool == CanvasTool.eraser,
        onPressed: () => onToolChanged(CanvasTool.eraser),
      ),
    ],
  );
}
