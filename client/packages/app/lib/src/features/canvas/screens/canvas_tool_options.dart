// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What each canvas tool offers beyond its plain press, as the rows of the
/// shared controls-with-options menu; a tool with none gets no caret.
library;

import 'package:flutter/material.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_slider_row.dart';
import '../../../widgets/control_swatch_row.dart';
import '../providers/canvas_pen_style.dart';
import '../widgets/canvas_custom_colours.dart';
import 'canvas_shape_icons.dart';

/// Only the pen and shape have options; the others return an empty list.
List<ControlOptionEntry> canvasToolOptions(
  CanvasTool tool, {
  required CanvasPenStyle pen,
  required ValueChanged<CanvasPenStyle> onPenChanged,
  required CanvasShapeKind shapeKind,
  required ValueChanged<CanvasShapeKind> onShapeKindChanged,
  List<ControlSwatch>? colours,
}) => switch (tool) {
  CanvasTool.pen => _penOptions(
    pen,
    onPenChanged,
    colours ??
        canvasPenColourSwatches(
          selectedKey: pen.colorKey,
          onChoose: (key) => onPenChanged(pen.copyWith(colorKey: key)),
        ),
  ),
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

/// The one colour row, then the size.
List<ControlOptionEntry> _penOptions(
  CanvasPenStyle pen,
  ValueChanged<CanvasPenStyle> onChanged,
  List<ControlSwatch> colours,
) => [
  ControlSwatchGroup(heading: 'Colour', swatches: colours),
  ControlSliderGroup(
    heading: 'Size',
    value: pen.width,
    min: canvasPenMinWidth,
    max: canvasPenMaxWidth,
    unit: 'px',
    previewColor: pen.color,
    onChanged: (width) => onChanged(pen.copyWith(width: width)),
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
