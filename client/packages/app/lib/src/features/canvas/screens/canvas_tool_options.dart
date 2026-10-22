// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What each canvas tool offers beyond its plain press, as the rows of the
/// shared controls-with-options menu; a tool with none gets no caret.
library;

import 'package:flutter/material.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart';
import '../providers/canvas_pen_style.dart';
import 'canvas_shape_icons.dart';

/// Only the pen and shape have options; the others return an empty list.
List<ControlOptionEntry> canvasToolOptions(
  CanvasTool tool, {
  required CanvasPenStyle pen,
  required ValueChanged<CanvasPenStyle> onPenChanged,
  required CanvasShapeKind shapeKind,
  required ValueChanged<CanvasShapeKind> onShapeKindChanged,
}) => switch (tool) {
  CanvasTool.pen => _penOptions(pen, onPenChanged),
  CanvasTool.shape => _shapeOptions(shapeKind, onShapeKindChanged),
  _ => const [],
};

/// Every kind, so `line` is not left reachable only from the overflow picker.
const canvasShapeOptionKinds = [
  CanvasShapeKind.rectangle,
  CanvasShapeKind.ellipse,
  CanvasShapeKind.line,
  CanvasShapeKind.arrow,
];

List<ControlOptionEntry> _penOptions(
  CanvasPenStyle pen,
  ValueChanged<CanvasPenStyle> onChanged,
) => [
  ControlSwatchGroup(
    heading: 'Colour',
    swatches: [
      for (final choice in canvasPenColors)
        ControlSwatch(
          label: choice.label,
          color: choice.color,
          selected: pen.colorKey == choice.key,
          onSelected: () => onChanged(pen.copyWith(colorKey: choice.key)),
        ),
    ],
  ),
  ControlSwatchGroup(
    heading: 'Width',
    swatches: [
      for (final choice in canvasPenWidths)
        ControlSwatch(
          label: choice.label,
          lineWidth: choice.width,
          selected: pen.width == choice.width,
          onSelected: () => onChanged(pen.copyWith(width: choice.width)),
        ),
    ],
  ),
];

List<ControlOption> _shapeOptions(
  CanvasShapeKind current,
  ValueChanged<CanvasShapeKind> onChanged,
) => [
  for (final kind in canvasShapeOptionKinds)
    ControlOption(
      label: canvasShapeKindLabel(kind),
      icon: canvasShapeKindIcon(kind),
      selected: current == kind,
      onSelected: () => onChanged(kind),
    ),
];
