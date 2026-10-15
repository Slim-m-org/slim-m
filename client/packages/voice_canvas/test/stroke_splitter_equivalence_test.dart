// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// CP6: `splitStroke` was rewritten to track its byte and extent budgets
/// incrementally instead of re-encoding the whole candidate segment on every
/// probe (which was O(L^2) in a segment's point count, run on the UI thread the
/// instant a stroke is finished). The rewrite must produce byte-for-byte the
/// same segmentation, because an over-budget segment is a 400 and ink already
/// on the drawer's screen vanishing.
///
/// This holds the new function against a verbatim copy of the pre-rewrite one,
/// over many seeded-random strokes of the shapes that stress each budget: a
/// random walk, a straight run, a monotone up-left walk (which moves the
/// segment origin on every point), tight clusters, and a wide sweep that trips
/// the extent limit. The style mirrors `spatial_grid_test.dart`, which keeps a
/// reference implementation beside the fast one and asserts they agree.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

// --- The pre-rewrite implementation, verbatim, as the oracle. ---

List<StrokeSegment> _reference(
  List<Offset> worldPoints, {
  int maxPropsBytes = 3500,
}) {
  if (worldPoints.isEmpty) return const <StrokeSegment>[];
  final segments = <StrokeSegment>[];
  var start = 0;
  var end = 1;
  while (start < worldPoints.length) {
    var candidate = end;
    while (candidate < worldPoints.length) {
      final next = candidate + 1;
      if (_refEncodedLength(worldPoints, start, next) > maxPropsBytes ||
          !_refWithinExtent(worldPoints, start, next)) {
        break;
      }
      candidate = next;
    }
    final stop = math.max(candidate, math.min(start + 2, worldPoints.length));
    segments.add(_refSegment(worldPoints, start, stop));
    if (stop >= worldPoints.length) break;
    start = stop - 1;
    end = start + 1;
  }
  return segments;
}

double _refQuantise(double v) => (v * 100).roundToDouble() / 100;

bool _refWithinExtent(List<Offset> points, int start, int stop) {
  final box = _refBounds(points, start, stop);
  return box.width <= maxObjectExtent && box.height <= maxObjectExtent;
}

Rect _refBounds(List<Offset> points, int start, int stop) {
  var minX = points[start].dx;
  var minY = points[start].dy;
  var maxX = minX;
  var maxY = minY;
  for (var i = start; i < stop; i++) {
    minX = math.min(minX, points[i].dx);
    minY = math.min(minY, points[i].dy);
    maxX = math.max(maxX, points[i].dx);
    maxY = math.max(maxY, points[i].dy);
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

StrokeSegment _refSegment(List<Offset> points, int start, int stop) {
  final box = _refBounds(points, start, stop);
  final x = _refQuantise(box.left);
  final y = _refQuantise(box.top);
  final flat = <double>[];
  for (var i = start; i < stop; i++) {
    flat
      ..add(_refQuantise(points[i].dx - x))
      ..add(_refQuantise(points[i].dy - y));
  }
  return StrokeSegment(
    x: x,
    y: y,
    w: _refQuantise(box.width),
    h: _refQuantise(box.height),
    points: flat,
  );
}

int _refEncodedLength(List<Offset> points, int start, int stop) =>
    jsonEncode(_refSegment(points, start, stop).points).length;

// --- Comparison and stroke generators. ---

void _expectSame(
    List<StrokeSegment> got, List<StrokeSegment> want, String how) {
  expect(got.length, want.length, reason: '$how: segment count');
  for (var i = 0; i < want.length; i++) {
    expect(got[i].x, want[i].x, reason: '$how: segment $i x');
    expect(got[i].y, want[i].y, reason: '$how: segment $i y');
    expect(got[i].w, want[i].w, reason: '$how: segment $i w');
    expect(got[i].h, want[i].h, reason: '$how: segment $i h');
    expect(got[i].points, want[i].points, reason: '$how: segment $i points');
  }
}

List<Offset> _walk(math.Random r, int n) {
  final pts = <Offset>[];
  var x = 0.0, y = 0.0;
  for (var i = 0; i < n; i++) {
    x += (r.nextDouble() - 0.5) * 8;
    y += (r.nextDouble() - 0.5) * 8;
    pts.add(Offset(x, y));
  }
  return pts;
}

List<Offset> _upLeft(math.Random r, int n) {
  final pts = <Offset>[];
  var x = 0.0, y = 0.0;
  for (var i = 0; i < n; i++) {
    // Monotone toward negative: the origin moves on nearly every point.
    x -= r.nextDouble() * 3;
    y -= r.nextDouble() * 3;
    pts.add(Offset(x, y));
  }
  return pts;
}

List<Offset> _cluster(math.Random r, int n) => [
      for (var i = 0; i < n; i++)
        Offset(r.nextDouble() * 0.5, r.nextDouble() * 0.5),
    ];

List<Offset> _straight(int n) =>
    [for (var i = 0; i < n; i++) Offset(i * 1.3, 0)];

List<Offset> _wide(int n) => [
      for (var i = 0; i < n; i++) Offset(i * 200.0, (i.isEven ? 0.0 : 50.0)),
    ];

/// Only one axis drifts, so the origin shifts on that axis while the other
/// stays put - the branch where the new and old origin partly agree.
List<Offset> _axisDrift(math.Random r, int n, {required bool xMoves}) {
  final pts = <Offset>[];
  var v = 0.0;
  for (var i = 0; i < n; i++) {
    v -= r.nextDouble() * 3;
    pts.add(xMoves ? Offset(v, 7.25) : Offset(7.25, v));
  }
  return pts;
}

void main() {
  test('the incremental split matches the reference on many random strokes',
      () {
    final r = math.Random(11);
    // Tiny budgets stress the tightest bracket/comma arithmetic; large ones the long single-segment case.
    for (final budget in [10, 30, 60, 200, 400, 900, 3500]) {
      for (var trial = 0; trial < 40; trial++) {
        final n = 1 + r.nextInt(600);
        final strokes = <(String, List<Offset>)>[
          ('walk', _walk(r, n)),
          ('upLeft', _upLeft(r, n)),
          ('cluster', _cluster(r, n)),
          ('straight', _straight(n)),
          ('wide', _wide(n)),
          ('xDrift', _axisDrift(r, n, xMoves: true)),
          ('yDrift', _axisDrift(r, n, xMoves: false)),
        ];
        for (final (name, pts) in strokes) {
          _expectSame(
            splitStroke(pts, maxPropsBytes: budget),
            _reference(pts, maxPropsBytes: budget),
            '$name n=$n budget=$budget',
          );
        }
      }
    }
  });

  test('boundary sizes still match the reference', () {
    for (final n in [0, 1, 2, 3]) {
      final pts = _straight(n);
      _expectSame(
        splitStroke(pts, maxPropsBytes: 3500),
        _reference(pts, maxPropsBytes: 3500),
        'straight n=$n',
      );
    }
  });

  test('a single step wider than the extent limit is subdivided', () {
    final segments = splitStroke(const [Offset(0, 0), Offset(9000, 0)]);

    expect(segments.length, greaterThan(1));
    for (final segment in segments) {
      expect(segment.w, lessThanOrEqualTo(maxObjectExtent));
      expect(segment.h, lessThanOrEqualTo(maxObjectExtent));
    }
    expect(
        segments.last.x + segments.last.points[segments.last.points.length - 2],
        closeTo(9000, 0.01));
  });
}
