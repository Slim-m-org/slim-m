// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one glyph each [CanvasShapeKind] gets, shared by the bar's own Shape
/// button (which one is armed) and the overflow menu's picker rows (which
/// one to pick) so the two surfaces cannot silently disagree.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

IconData canvasShapeKindIcon(CanvasShapeKind kind) => switch (kind) {
  CanvasShapeKind.rectangle => AppIcons.shapeRectangle,
  CanvasShapeKind.ellipse => AppIcons.shapeEllipse,
  CanvasShapeKind.line => AppIcons.shapeLine,
  CanvasShapeKind.arrow => AppIcons.shapeArrow,
};

/// The label a picker row shows beside [canvasShapeKindIcon], and what the
/// bar's own tooltip names as armed - the one place a screen reader learns
/// which kind is current, since the icon change is a visual-only channel.
String canvasShapeKindLabel(CanvasShapeKind kind) => switch (kind) {
  CanvasShapeKind.rectangle => 'Rectangle',
  CanvasShapeKind.ellipse => 'Ellipse',
  CanvasShapeKind.line => 'Line',
  CanvasShapeKind.arrow => 'Arrow',
};
