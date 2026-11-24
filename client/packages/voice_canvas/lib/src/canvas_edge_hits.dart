// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a pointer lands on among the edges: the line, a label, an end handle or a side dot.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'canvas_edge_route.dart';
import 'canvas_edge_spec.dart';
import 'canvas_edges.dart';

/// Painted width of an edge's line in world units.
const double edgeLineWidth = 2.5;

/// How far a pointer may sit from the line and still hit it, in screen pixels.
const double edgeHitSlopPx = 6;

/// [edgeHitSlopPx] for a finger.
const double edgeTouchHitSlopPx = 14;

/// The visual size of a side dot, screen pixels.
const double sideDotSizePx = 10;

/// How far a pointer may sit from a side dot and still grab it: 30 for a pointer, 44 for a finger.
const double sideDotReachPx = 15;
const double sideDotTouchReachPx = 22;

/// The side of an end handle's hit disc, screen pixels.
const double edgeHandleReachPx = 14;
const double edgeHandleTouchReachPx = 22;

/// The four dots of [box], keyed by side.
Map<EdgeSide, Offset> sideDots(Rect box) => {
      EdgeSide.top: box.topCenter,
      EdgeSide.right: box.centerRight,
      EdgeSide.bottom: box.bottomCenter,
      EdgeSide.left: box.centerLeft,
    };

/// The side dot of [box] within reach of [world], the nearest when two are.
EdgeSide? sideDotAt(
  Rect box,
  Offset world, {
  required double zoom,
  bool touch = false,
}) {
  final reach = (touch ? sideDotTouchReachPx : sideDotReachPx) / zoom;
  EdgeSide? best;
  var bestDistance = reach;
  for (final entry in sideDots(box).entries) {
    final distance = (entry.value - world).distance;
    if (distance <= bestDistance) {
      best = entry.key;
      bestDistance = distance;
    }
  }
  return best;
}

/// The side of [box] a pointer at [world] is nearest, for snapping a release near an object.
EdgeSide nearestSide(Rect box, Offset world) => facingSide(box, world);

/// Where an edge's label chip sits, in world units, for a label of [size] on a route.
Rect labelRect(EdgeRoute route, Size size) => Rect.fromCenter(
    center: route.midpoint, width: size.width, height: size.height);

/// How an edge end is described to a hit test: which end of which edge.
typedef EdgeEndRef = ({String edgeId, bool isTo});

extension CanvasEdgeHits on CanvasEdges {
  /// The topmost live edge whose line, or label chip, is within reach of [world].
  /// [labelSize] measures a label in world units; null skips labels.
  String? hitEdge(
    Offset world, {
    required double zoom,
    bool touch = false,
    Size Function(String label)? labelSize,
  }) {
    final slop = (touch ? edgeTouchHitSlopPx : edgeHitSlopPx) / zoom;
    for (final edge in inPaintOrder.reversed) {
      final route = routeOf(edge);
      if (route == null) continue;
      final reach = edgeLineWidth / 2 + slop;
      if (!edgeBounds(route).inflate(reach).contains(world)) continue;
      if (distanceToEdge(route, world) <= reach) return edge.id;
      final label = edge.spec.label;
      if (label != null &&
          labelSize != null &&
          labelRect(route, labelSize(label)).inflate(slop).contains(world)) {
        return edge.id;
      }
    }
    return null;
  }

  /// An end handle of the selected edge within reach of [world].
  EdgeEndRef? hitEndHandle(
    Offset world, {
    required double zoom,
    bool touch = false,
  }) {
    final edge = selected;
    final route = edge == null ? null : routeOf(edge);
    if (edge == null || route == null) return null;
    final reach = (touch ? edgeHandleTouchReachPx : edgeHandleReachPx) / zoom;
    final toStart = (route.start - world).distance;
    final toEnd = (route.end - world).distance;
    final nearest = math.min(toStart, toEnd);
    if (nearest > reach) return null;
    return (edgeId: edge.id, isTo: toEnd <= toStart);
  }
}
