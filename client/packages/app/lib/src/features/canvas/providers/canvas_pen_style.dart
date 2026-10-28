// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pen's colour and width choices, and the style a stroke is drawn in.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// Active pen style choice, preserved across canvas pane opens.
final canvasActivePenStyleProvider = StateProvider<CanvasPenStyle?>(
  (ref) => null,
);

/// Active shape kind choice, preserved across canvas pane opens.
final canvasActiveShapeKindProvider = StateProvider<CanvasShapeKind>(
  (ref) => CanvasShapeKind.rectangle,
);

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

/// The pen colour nearest [colour] by hue, so a profile colour picks a pen that reads as the same colour; greys keep the default.
String nearestPenColorKey(Color colour) {
  final target = HSVColor.fromColor(colour);
  if (target.saturation < 0.2 || target.value < 0.2) {
    return canvasDefaultPenColorKey;
  }
  var best = canvasDefaultPenColorKey;
  var bestDistance = double.infinity;
  for (final pen in canvasPenColors) {
    final raw = (HSVColor.fromColor(pen.color).hue - target.hue).abs();
    final distance = raw > 180 ? 360 - raw : raw;
    if (distance < bestDistance) {
      bestDistance = distance;
      best = pen.key;
    }
  }
  return best;
}

/// What a colour key paints as, handed to the surface so strokes drawn by
/// anyone render in the colour they were drawn in.
final canvasPenInkByKey = {
  for (final pen in canvasPenColors) pen.key: pen.color,
};

/// The world width a stroke is stored with, so [screenPx] looks the same on the drawer's screen at any zoom.
double canvasPenWorldWidth(double screenPx, double zoom) => screenPx / zoom;

/// The pen's size range in screen pixels on the drawer's own screen, as the slider offers it.
const canvasPenMinWidth = 1.0;
const canvasPenMaxWidth = 24.0;

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
