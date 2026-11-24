// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where an edge runs: its sides, its curve, its arrowheads and how far a point is from it.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const left = Rect.fromLTWH(0, 0, 100, 50);
const right = Rect.fromLTWH(300, 0, 100, 50);
const below = Rect.fromLTWH(0, 300, 100, 50);

CanvasEdgeSpec between(
        {EdgeSide from = EdgeSide.auto, EdgeSide to = EdgeSide.auto}) =>
    CanvasEdgeSpec(
        from: AttachedEnd('a', side: from), to: AttachedEnd('b', side: to));

void main() {
  test('auto leaves the sides that face each other', () {
    final route = routeEdge(between(), left, right)!;
    expect(route.startSide, EdgeSide.right);
    expect(route.endSide, EdgeSide.left);
    expect(route.start, left.centerRight);
    expect(route.end, right.centerLeft);

    final down = routeEdge(between(), left, below)!;
    expect(down.startSide, EdgeSide.bottom);
    expect(down.endSide, EdgeSide.top);
  });

  test('an explicit side wins and the curve leaves it perpendicular', () {
    final route =
        routeEdge(between(from: EdgeSide.top, to: EdgeSide.top), left, right)!;
    expect(route.start, left.topCenter);
    expect(route.control1.dx, route.start.dx);
    expect(route.control1.dy, lessThan(route.start.dy));
    expect(route.control2.dy, lessThan(route.end.dy));
  });

  test('an end that is not held yet has no route', () {
    expect(routeEdge(between(), left, null), isNull);
    expect(routeEdge(between(), null, right), isNull);
  });

  test('a free end ends exactly where it was dropped', () {
    const spec = CanvasEdgeSpec(
      from: AttachedEnd('a'),
      to: FreeEnd(Offset(500, 25)),
    );
    final route = routeEdge(spec, left, null)!;
    expect(route.end, const Offset(500, 25));
    expect(route.endSide, isNull);
    expect(route.pointAt(1), const Offset(500, 25));
  });

  test('the arrowhead points along the curve into the end', () {
    final route = routeEdge(between(), left, right)!;
    final head = route.endHead(EdgeArrow.end)!;
    expect(head.first, route.end);
    expect(head[1].dx, lessThan(route.end.dx));
    expect(head[2].dx, lessThan(route.end.dx));
    expect(head[1].dy, isNot(head[2].dy));
    expect(route.endHead(EdgeArrow.none), isNull);
    expect(route.startHead(EdgeArrow.end), isNull);
    expect(route.startHead(EdgeArrow.both)!.first, route.start);
  });

  test('two boxes at the same place do not produce a NaN route', () {
    final route = routeEdge(between(), left, left)!;
    expect(route.midpoint.dx.isFinite && route.midpoint.dy.isFinite, isTrue);
  });

  test('distance to an edge is zero on the curve and grows away from it', () {
    final route = routeEdge(between(), left, right)!;
    expect(distanceToEdge(route, route.midpoint), closeTo(0, 0.5));
    expect(distanceToEdge(route, route.midpoint + const Offset(0, 40)),
        closeTo(40, 1));
  });
}
