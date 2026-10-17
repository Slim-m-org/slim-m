// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the tool strip shows, in what order, and which key arms each tool.
library;

import 'package:flutter/services.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// Left to right in the tool strip; decision 0047 point 5.
const canvasToolOrder = [
  CanvasTool.pan,
  CanvasTool.pen,
  CanvasTool.note,
  CanvasTool.shape,
  CanvasTool.eraser,
];

/// Open question in decision 0047: true makes pan the opening tool at every width.
const canvasPanDefaultsEverywhere = false;

/// Width decides, never platform (desktop-vs-mobile law 1), so a phone gets pan and a desktop window gets the pen.
CanvasTool canvasDefaultTool({required bool compact}) =>
    canvasPanDefaultsEverywhere || compact ? CanvasTool.pan : CanvasTool.pen;

extension CanvasToolInput on CanvasTool {
  LogicalKeyboardKey get shortcutKey => switch (this) {
    CanvasTool.pan => LogicalKeyboardKey.keyH,
    CanvasTool.pen => LogicalKeyboardKey.keyP,
    CanvasTool.note => LogicalKeyboardKey.keyN,
    CanvasTool.shape => LogicalKeyboardKey.keyS,
    CanvasTool.eraser => LogicalKeyboardKey.keyE,
  };

  /// The tools that put a new object on the canvas; they need the canvas to be writable.
  bool get placesObjects =>
      this == CanvasTool.pen ||
      this == CanvasTool.note ||
      this == CanvasTool.shape;

  /// One rule for the button and the key, so the key never does what the button could not.
  bool isAvailable({required bool canDraw}) => canDraw || !placesObjects;
}
