// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ellipses drawn as short line segments.
///
/// Impeller's OpenGL renderer on Linux (Flutter 3.47, "OpenGLESSDF") paints a
/// large stroked or filled oval or circle as a blocky shape over its whole
/// bounding box; `drawOval` and `Path.addOval` both reach that path, while a
/// polyline draws correctly. Reproduced in a standalone build, 2026-11-07.
library;

import 'dart:math' as math;
import 'dart:ui';

/// Segments per ellipse: under half a pixel off the true curve at 1300 logical pixels across.
const ellipseSegments = 128;

/// [rect]'s ellipse as a closed polyline.
Path ellipsePolyline(Rect rect) {
  final path = Path();
  final cx = rect.center.dx;
  final cy = rect.center.dy;
  final rx = rect.width / 2;
  final ry = rect.height / 2;
  path.moveTo(cx + rx, cy);
  for (var i = 1; i < ellipseSegments; i++) {
    final t = i / ellipseSegments * 2 * math.pi;
    path.lineTo(cx + rx * math.cos(t), cy + ry * math.sin(t));
  }
  return path..close();
}

/// Draws [rect]'s ellipse with [paint], stroked or filled, without `drawOval`.
void drawEllipse(Canvas canvas, Rect rect, Paint paint) =>
    canvas.drawPath(ellipsePolyline(rect), paint);
