// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What an `edge` object holds (decision 0137): two ends, an arrow, a colour and a label.
///
/// No JSON library and no api types: the app maps a wire object's `props` map onto this.
library;

import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Which side of an attached object an edge leaves from; `auto` picks the facing one.
enum EdgeSide { auto, top, right, bottom, left }

/// Where an edge draws its arrowheads.
enum EdgeArrow { none, end, both }

/// Longest label, matching the server's `MAX_LABEL_CHARS`.
const int maxEdgeLabelChars = 120;

/// Most live edges one object may carry, matching the server's `MAX_EDGES_PER_OBJECT`.
const int maxEdgesPerObject = 64;

/// One end of an edge: stuck to an object, or left at a point of the world.
@immutable
sealed class EdgeEndSpec {
  const EdgeEndSpec();
}

final class AttachedEnd extends EdgeEndSpec {
  const AttachedEnd(this.objectId, {this.side = EdgeSide.auto});

  final String objectId;
  final EdgeSide side;

  @override
  bool operator ==(Object other) =>
      other is AttachedEnd && other.objectId == objectId && other.side == side;

  @override
  int get hashCode => Object.hash(objectId, side);
}

final class FreeEnd extends EdgeEndSpec {
  const FreeEnd(this.point);

  final Offset point;

  @override
  bool operator ==(Object other) => other is FreeEnd && other.point == point;

  @override
  int get hashCode => point.hashCode;
}

EdgeEndSpec? _endFrom(Object? raw) {
  if (raw is! Map) return null;
  final id = raw['object_id'];
  if (id is String && id.isNotEmpty) {
    final side = EdgeSide.values.asNameMap()[raw['side']] ?? EdgeSide.auto;
    return AttachedEnd(id, side: side);
  }
  final x = raw['x'];
  final y = raw['y'];
  if (x is num && y is num && x.isFinite && y.isFinite) {
    return FreeEnd(Offset(x.toDouble(), y.toDouble()));
  }
  return null;
}

/// The wire props of one end.
Map<String, Object?> edgeEndToProps(EdgeEndSpec end) => switch (end) {
      AttachedEnd(:final objectId, :final side) => {
          'object_id': objectId,
          if (side != EdgeSide.auto) 'side': side.name,
        },
      FreeEnd(:final point) => {'x': point.dx, 'y': point.dy},
    };

/// The props of one edge. At least one end is attached, and the two never name the same object.
@immutable
class CanvasEdgeSpec {
  const CanvasEdgeSpec({
    required this.from,
    required this.to,
    this.arrow = EdgeArrow.end,
    this.colorKey,
    this.label,
  });

  final EdgeEndSpec from;
  final EdgeEndSpec to;
  final EdgeArrow arrow;

  /// A palette key or `#rrggbb`; null draws the board's neutral ink.
  final String? colorKey;
  final String? label;

  /// The spec a wire object's props describe, or null for anything this client cannot draw.
  static CanvasEdgeSpec? fromProps(Map<String, Object?> props) {
    final from = _endFrom(props['from']);
    final to = _endFrom(props['to']);
    if (from == null || to == null) return null;
    final spec = CanvasEdgeSpec(
      from: from,
      to: to,
      arrow: EdgeArrow.values.asNameMap()[props['arrow']] ?? EdgeArrow.end,
      colorKey: props['color'] is String ? props['color'] as String : null,
      label: props['label'] is String && (props['label'] as String).isNotEmpty
          ? props['label'] as String
          : null,
    );
    return spec.isValid ? spec : null;
  }

  /// Whether the ends obey the rules the server enforces.
  bool get isValid {
    final ids = attachedIds.toList();
    if (ids.isEmpty) return false;
    return ids.length < 2 || ids[0] != ids[1];
  }

  /// The objects this edge hangs on, in `from`, `to` order.
  Iterable<String> get attachedIds sync* {
    if (from case AttachedEnd(:final objectId)) yield objectId;
    if (to case AttachedEnd(:final objectId)) yield objectId;
  }

  Map<String, Object?> toProps() => {
        'from': edgeEndToProps(from),
        'to': edgeEndToProps(to),
        'arrow': arrow.name,
        if (colorKey != null) 'color': colorKey,
        if (label != null) 'label': label,
      };

  CanvasEdgeSpec copyWith({
    EdgeEndSpec? from,
    EdgeEndSpec? to,
    EdgeArrow? arrow,
    String? colorKey,
    bool clearColor = false,
    String? label,
    bool clearLabel = false,
  }) =>
      CanvasEdgeSpec(
        from: from ?? this.from,
        to: to ?? this.to,
        arrow: arrow ?? this.arrow,
        colorKey: clearColor ? null : colorKey ?? this.colorKey,
        label: clearLabel ? null : label ?? this.label,
      );

  @override
  bool operator ==(Object other) =>
      other is CanvasEdgeSpec &&
      other.from == from &&
      other.to == to &&
      other.arrow == arrow &&
      other.colorKey == colorKey &&
      other.label == label;

  @override
  int get hashCode => Object.hash(from, to, arrow, colorKey, label);
}

/// The plain union of the end boxes and free points as `(x, y, w, h)`, never clamped.
///
/// The server stores the same function's answer; `schema/test-vectors/canvas_edge_hull.json` pins both.
({double x, double y, double w, double h}) edgeHull(Iterable<Rect> parts) {
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  for (final part in parts) {
    if (part.left < minX) minX = part.left;
    if (part.top < minY) minY = part.top;
    if (part.right > maxX) maxX = part.right;
    if (part.bottom > maxY) maxY = part.bottom;
  }
  return (x: minX, y: minY, w: maxX - minX, h: maxY - minY);
}
