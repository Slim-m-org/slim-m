// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pen's colour and width choices, and the style a stroke is drawn in.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:slimm_design_system/design_system.dart';

/// One pen colour: [key] is what a stroke carries on the wire as `color`.
class CanvasPenColor {
  const CanvasPenColor(this.key, this.label, this.color);

  final String key;
  final String label;
  final Color color;
}

/// [canvasDefaultPenColorKey] stays first and keeps the key every stroke
/// drawn before this picker existed already carries.
const canvasPenColors = [
  CanvasPenColor('annotation', 'Coral', AppCanvasColors.annotation),
  CanvasPenColor('amber', 'Amber', AppCanvasColors.note),
  CanvasPenColor('green', 'Green', AppCanvasColors.penGreen),
  CanvasPenColor('blue', 'Blue', AppCanvasColors.shape),
  CanvasPenColor('purple', 'Purple', AppCanvasColors.penPurple),
  CanvasPenColor('pink', 'Pink', AppCanvasColors.penPink),
];

const canvasDefaultPenColorKey = 'annotation';

/// What a colour key paints as, handed to the surface so strokes drawn by
/// anyone render in the colour they were drawn in.
final canvasPenInkByKey = {
  for (final pen in canvasPenColors) pen.key: pen.color,
};

/// One pen width, in world units, the same quantity a stroke's `width` holds.
class CanvasPenWidth {
  const CanvasPenWidth(this.label, this.width);

  final String label;
  final double width;
}

const canvasPenWidths = [
  CanvasPenWidth('Thin', 1.5),
  CanvasPenWidth('Medium', 3),
  CanvasPenWidth('Thick', 6),
];

/// Medium is what every stroke was before the width was a choice.
const canvasDefaultPenWidth = 3.0;

/// The pen as armed: the next stroke takes this colour and width.
@immutable
class CanvasPenStyle {
  const CanvasPenStyle({
    this.colorKey = canvasDefaultPenColorKey,
    this.width = canvasDefaultPenWidth,
  });

  final String colorKey;
  final double width;

  CanvasPenStyle copyWith({String? colorKey, double? width}) => CanvasPenStyle(
    colorKey: colorKey ?? this.colorKey,
    width: width ?? this.width,
  );

  Color get color => canvasPenInkByKey[colorKey] ?? AppCanvasColors.annotation;

  @override
  bool operator ==(Object other) =>
      other is CanvasPenStyle &&
      other.colorKey == colorKey &&
      other.width == width;

  @override
  int get hashCode => Object.hash(colorKey, width);
}
