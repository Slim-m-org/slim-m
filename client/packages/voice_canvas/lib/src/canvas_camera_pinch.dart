// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A two-finger pinch's effect on the camera, as a pure function.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'canvas_stroke.dart';

/// The camera a pinch has reached: [start] zoomed by [scale], with the world point [anchor] under [focal].
/// One result rather than a zoom followed by a pan, since each camera change culls and notifies every listener.
Camera cameraAfterPinch(
  Camera start, {
  required Offset anchor,
  required Offset focal,
  required double scale,
  double zoomFloor = minZoom,
}) {
  final zoom = (start.zoom * scale)
      .clamp(zoomFloor, math.max(zoomFloor, maxZoom))
      .toDouble();
  return start.copyWith(
    x: anchor.dx - focal.dx / zoom,
    y: anchor.dy - focal.dy / zoom,
    zoom: zoom,
  );
}
