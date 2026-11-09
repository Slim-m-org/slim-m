// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two questions tests ask of `hitTestTopmost`: which pen stroke, and which box object, a point lands on.
library;

import 'dart:ui';

import 'package:slimm_voice_canvas/voice_canvas.dart';

/// The topmost live pen stroke at [world].
String? strokeHitAt(
  CanvasDocument document,
  Offset world, {
  bool touch = false,
  bool Function(CanvasStroke stroke)? allowed,
}) =>
    hitTestTopmost(
      document,
      world,
      touch: touch,
      allowed: allowed,
      accepts: (stroke) => stroke.kind == CanvasObjectKind.stroke,
    );

/// The topmost live image, note, shape or text box at [world].
String? boxHitAt(
  CanvasDocument document,
  Offset world, {
  bool touch = false,
  bool Function(CanvasStroke stroke)? allowed,
}) =>
    hitTestTopmost(
      document,
      world,
      touch: touch,
      allowed: allowed,
      accepts: (stroke) => stroke.kind != CanvasObjectKind.stroke,
    );
