// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning a drawn polyline into objects the server will accept.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'canvas_document.dart';

/// One segment of a drawn stroke, ready to be sent.
@immutable
class StrokeSegment {
  const StrokeSegment({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.points,
  });

  final double x;
  final double y;
  final double w;
  final double h;

  /// Relative to [x] and [y], quantised, ready to encode.
  final List<double> points;
}

/// Splits a drawn polyline into objects the server will accept.
///
/// Budgeted by *encoded bytes*, never by a point count, and that is the whole
/// reason this is a function with a test rather than a constant. A point count
/// says nothing about how long the JSON is: Dart emits shortest-round-trip
/// doubles, so 512 unquantised coordinates run from four characters to
/// seventeen and a legal-looking stroke straddles the ceiling. Over it the
/// server answers 400 and ink already on the drawer's own screen disappears,
/// which is the worst failure this surface has.
///
/// Coordinates are quantised to two decimals first, which bounds a point to
/// nine characters given [maxObjectExtent], and each segment repeats the
/// previous one's last point so a split leaves no visible seam.
List<StrokeSegment> splitStroke(
  List<Offset> rawPoints, {
  int maxPropsBytes = 3500,
}) {
  if (rawPoints.isEmpty) return const <StrokeSegment>[];
  final worldPoints = _withinExtentSteps(rawPoints);
  final segments = <StrokeSegment>[];
  var start = 0;
  while (start < worldPoints.length) {
    final candidate = _growSegment(worldPoints, start, maxPropsBytes);
    // At least two points, or a single tap never becomes a mark at all.
    final stop = math.max(candidate, math.min(start + 2, worldPoints.length));
    segments.add(_segment(worldPoints, start, stop));
    if (stop >= worldPoints.length) break;
    start = stop - 1;
  }
  return segments;
}

/// Inserts points into any step wider than [maxObjectExtent], because the
/// forced two-point segment below skips the extent check and one such step
/// would otherwise be a segment the server refuses.
List<Offset> _withinExtentSteps(List<Offset> points) {
  var needsWork = false;
  for (var i = 1; i < points.length; i++) {
    if (_stepParts(points[i - 1], points[i]) > 1) needsWork = true;
  }
  if (!needsWork) return points;
  final out = <Offset>[points.first];
  for (var i = 1; i < points.length; i++) {
    final parts = _stepParts(points[i - 1], points[i]);
    for (var k = 1; k < parts; k++) {
      out.add(Offset.lerp(points[i - 1], points[i], k / parts)!);
    }
    out.add(points[i]);
  }
  return out;
}

int _stepParts(Offset a, Offset b) {
  final longest = math.max((b.dx - a.dx).abs(), (b.dy - a.dy).abs());
  return (longest / maxObjectExtent).ceil();
}

/// The largest `candidate` for which the segment `[start, candidate)` still
/// fits the byte and extent budgets, growing one point at a time.
///
/// Both budgets are tracked incrementally so each step is O(1), rather than
/// re-deriving the whole segment's bounds and re-encoding its whole point list
/// on every probe (which made the old scan O(L^2) in a segment's length). The
/// bounding box only ever grows, so extent is a running min/max; the encoded
/// length is a running sum of each coordinate's JSON length, recomputed only
/// when a new point moves the origin the coordinates are stored relative to.
/// The result is identical to re-encoding from scratch at each point, which the
/// equivalence test pins against the pre-existing implementation.
int _growSegment(List<Offset> points, int start, int maxPropsBytes) {
  final len = points.length;
  var candidate = start + 1;
  if (candidate >= len) return candidate;

  var minX = points[start].dx;
  var minY = points[start].dy;
  var maxX = minX;
  var maxY = minY;
  var originX = _quantise(minX);
  var originY = _quantise(minY);
  var count = 2;
  var exact = true;
  var sumNumLen =
      _numLen(points[start].dx - originX) + _numLen(points[start].dy - originY);

  while (candidate < len) {
    final p = points[candidate];
    final newMinX = math.min(minX, p.dx);
    final newMinY = math.min(minY, p.dy);
    final newMaxX = math.max(maxX, p.dx);
    final newMaxY = math.max(maxY, p.dy);
    if (newMaxX - newMinX > maxObjectExtent ||
        newMaxY - newMinY > maxObjectExtent) {
      break;
    }

    final newOriginX = _quantise(newMinX);
    final newOriginY = _quantise(newMinY);
    final newCount = count + 2;
    final points2 = newCount ~/ 2;
    final bound = 2 +
        points2 *
            (_maxNumLen(newMaxX - newMinX) + _maxNumLen(newMaxY - newMinY)) +
        (newCount - 1);
    // A bound that fits proves the exact length fits, so the O(L) re-encode on an origin move only runs near the ceiling.
    var newSumNumLen = sumNumLen;
    var newExact = false;
    if (bound > maxPropsBytes) {
      if (exact && newOriginX == originX && newOriginY == originY) {
        newSumNumLen =
            sumNumLen + _numLen(p.dx - originX) + _numLen(p.dy - originY);
      } else {
        var sum = 0;
        for (var i = start; i <= candidate; i++) {
          sum += _numLen(points[i].dx - newOriginX);
          sum += _numLen(points[i].dy - newOriginY);
        }
        newSumNumLen = sum;
      }
      newExact = true;
      // jsonEncode of a list is "[" + numbers joined by "," + "]".
      if (2 + newSumNumLen + (newCount - 1) > maxPropsBytes) break;
    }

    candidate++;
    minX = newMinX;
    minY = newMinY;
    maxX = newMaxX;
    maxY = newMaxY;
    originX = newOriginX;
    originY = newOriginY;
    count = newCount;
    sumNumLen = newSumNumLen;
    exact = newExact;
  }
  return candidate;
}

/// The longest a coordinate in `[0, extent]` can encode: all its whole digits, a point and two decimals.
int _maxNumLen(double extent) => _digits(extent.ceil() + 1) + 3;

double _quantise(double v) => (v * 100).roundToDouble() / 100;

/// The JSON-encoded length of one coordinate, quantised the way [_segment]
/// stores it, so a running sum of these equals re-encoding the whole list.
int _numLen(double relative) {
  final q = _quantise(relative);
  final cents = (q.abs() * 100).round();
  final whole = cents ~/ 100;
  final fraction = cents % 100;
  final fractionDigits = fraction == 0 ? 1 : (fraction % 10 == 0 ? 1 : 2);
  return (q.isNegative ? 1 : 0) + _digits(whole) + 1 + fractionDigits;
}

int _digits(int n) {
  var digits = 1;
  for (var rest = n ~/ 10; rest > 0; rest ~/= 10) {
    digits++;
  }
  return digits;
}

/// The reference [_numLen] is verified against.
@visibleForTesting
int debugJsonNumLen(double relative) => jsonEncode(_quantise(relative)).length;

@visibleForTesting
int debugNumLen(double relative) => _numLen(relative);

Rect _bounds(List<Offset> points, int start, int stop) {
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

StrokeSegment _segment(List<Offset> points, int start, int stop) {
  final box = _bounds(points, start, stop);
  final x = _quantise(box.left);
  final y = _quantise(box.top);
  final flat = <double>[];
  for (var i = start; i < stop; i++) {
    flat
      ..add(_quantise(points[i].dx - x))
      ..add(_quantise(points[i].dy - y));
  }
  return StrokeSegment(
    x: x,
    y: y,
    w: _quantise(box.width),
    h: _quantise(box.height),
    points: flat,
  );
}
