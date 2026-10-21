// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pen paths round their corners but still start and end on the real samples.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_smooth_path.dart';

double _length(Path path) =>
    path.computeMetrics().fold(0.0, (sum, m) => sum + m.length);

void main() {
  test('a corner is cut, so the path is shorter than the polyline', () {
    final path = smoothPolyline([0, 0, 10, 0, 10, 10]);
    expect(_length(path), lessThan(20));
    expect(_length(path), greaterThan(14));
  });

  test('the path starts and ends on the first and last samples', () {
    final path = smoothPolyline([0, 0, 10, 0, 10, 10, 20, 10]);
    final metric = path.computeMetrics().single;
    expect(metric.getTangentForOffset(0)!.position, const Offset(0, 0));
    expect(
      metric.getTangentForOffset(metric.length)!.position,
      const Offset(20, 10),
    );
  });

  test('one sample is a dot and two are a straight line', () {
    expect(smoothPolyline([5, 5]).getBounds(), const Rect.fromLTWH(5, 5, 0, 0));
    expect(_length(smoothPolyline([0, 0, 3, 4])), closeTo(5, 1e-6));
    expect(smoothPolyline(const []).getBounds(), Rect.zero);
  });

  test('an offset moves the whole path', () {
    final bounds = smoothPolyline([0, 0, 10, 10], dx: 5, dy: 7).getBounds();
    expect(bounds, const Rect.fromLTRB(5, 7, 15, 17));
  });
}
