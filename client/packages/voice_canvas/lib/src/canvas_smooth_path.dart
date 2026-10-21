// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pen paths drawn through midpoints, so quick curves read as curves.
library;

import 'dart:ui';

/// A path through the polyline `[x0, y0, x1, y1, ...]` offset by ([dx], [dy]): samples are control points and midpoints are on the curve, so the stroke never overshoots and stored points stay raw.
Path smoothPolyline(List<double> flat, {double dx = 0, double dy = 0}) {
  final path = Path();
  final count = flat.length ~/ 2;
  if (count == 0) return path;
  double x(int i) => flat[2 * i] + dx;
  double y(int i) => flat[2 * i + 1] + dy;
  path.moveTo(x(0), y(0));
  if (count == 1) return path..lineTo(x(0), y(0));
  if (count == 2) return path..lineTo(x(1), y(1));
  for (var i = 1; i < count - 1; i++) {
    path.quadraticBezierTo(
      x(i),
      y(i),
      (x(i) + x(i + 1)) / 2,
      (y(i) + y(i + 1)) / 2,
    );
  }
  return path..lineTo(x(count - 1), y(count - 1));
}
