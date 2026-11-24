// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Painting edges (decision 0137): the lines and labels under the ink, and the affordances over it.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'canvas_document.dart';
import 'canvas_edge_hits.dart';
import 'canvas_edge_route.dart';
import 'canvas_edge_spec.dart';
import 'canvas_edges.dart';
import 'canvas_ink.dart';

/// Label type size in world units, so a label scales with the board like the line it sits on.
const double edgeLabelFontSize = 14;
const EdgeInsets _labelPadding =
    EdgeInsets.symmetric(horizontal: 8, vertical: 3);

/// Lays out one edge label; shared by painting and by hit testing so the chip a person sees is the chip they hit.
class EdgeLabels {
  EdgeLabels({this.fontFamily});

  final String? fontFamily;
  final Map<String, TextPainter> _cache = {};

  TextPainter _painter(String label, Color color) {
    final key = '${color.toARGB32()}\u0000$label';
    if (_cache.length > 128) _cache.clear();
    return _cache.putIfAbsent(
      key,
      () => TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: color,
            fontSize: edgeLabelFontSize,
            fontFamily: fontFamily,
            height: 1.2,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 360),
    );
  }

  /// The chip size of [label] in world units.
  Size sizeOf(String label) {
    final painter = _painter(label, const Color(0xFF000000));
    return Size(
      painter.width + _labelPadding.horizontal,
      painter.height + _labelPadding.vertical,
    );
  }

  void paint(
      Canvas canvas, Offset centre, String label, Color ink, Color fill) {
    final painter = _painter(label, ink);
    final chip = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: centre,
        width: painter.width + _labelPadding.horizontal,
        height: painter.height + _labelPadding.vertical,
      ),
      const Radius.circular(8),
    );
    canvas.drawRRect(chip, Paint()..color = fill);
    canvas.drawRRect(
      chip,
      Paint()
        ..color = ink.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    painter.paint(
      canvas,
      centre - Offset(painter.width / 2, painter.height / 2),
    );
  }

  void dispose() {
    for (final painter in _cache.values) {
      painter.dispose();
    }
    _cache.clear();
  }
}

/// The edge lines, labels and arrowheads, under the committed ink.
class EdgePainter extends CustomPainter {
  EdgePainter({
    required this.document,
    required this.ink,
    required this.inkColors,
    required this.labelFill,
    required this.labels,
  }) : super(repaint: document);

  final CanvasDocument document;

  /// The board's neutral ink, which an edge without a colour of its own draws in.
  final Color ink;
  final Map<String, Color> inkColors;
  final Color labelFill;
  final EdgeLabels labels;

  Color colourOf(CanvasEdge edge) =>
      resolveCanvasInk(inkColors, edge.spec.colorKey, ink);

  @override
  void paint(Canvas canvas, Size size) {
    final edges = document.edges;
    if (edges.liveCount == 0) return;
    final camera = document.camera;
    final view = document.worldView.inflate(40);
    canvas
      ..save()
      ..scale(camera.zoom)
      ..translate(-camera.x, -camera.y);
    for (final edge in edges.inPaintOrder) {
      final route = edges.routeOf(edge);
      if (route == null || !edgeBounds(route).overlaps(view)) continue;
      final colour = colourOf(edge);
      final line = Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = edgeLineWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(route.path, line);
      final heads = [
        route.endHead(edge.spec.arrow),
        route.startHead(edge.spec.arrow),
      ];
      for (final head in heads.whereType<List<Offset>>()) {
        canvas.drawPath(
          Path()..addPolygon(head, true),
          Paint()
            ..color = colour
            ..style = PaintingStyle.fill,
        );
      }
      if (edge.spec.label case final label?) {
        labels.paint(canvas, route.midpoint, label, colour, labelFill);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(EdgePainter old) => !identical(old, this);
}

/// What is drawn over the ink for edges: the selected edge and its end handles, the side dots, and the edge being drawn.
class EdgeOverlayPainter extends CustomPainter {
  EdgeOverlayPainter({
    required this.document,
    required this.outline,
    required this.handleFill,
    required this.handleBorder,
    this.touchHandles = false,
  }) : super(
          repaint: Listenable.merge([
            document,
            document.selectedObjectId,
            document.edges.draft,
            document.edges.dotsOn,
          ]),
        );

  final CanvasDocument document;
  final Color outline;
  final Color handleFill;
  final Color handleBorder;
  final bool touchHandles;

  Offset _screen(Offset world) {
    final c = document.camera;
    return Offset((world.dx - c.x) * c.zoom, (world.dy - c.y) * c.zoom);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final edges = document.edges;
    _paintSelected(canvas, edges);
    final draft = edges.draft.value;
    if (draft != null) _paintDraft(canvas, edges, draft);
    final dotted = edges.dotsOn.value;
    final box = dotted == null ? null : edges.boxOf(dotted);
    if (box != null) {
      _paintDots(canvas, box, draft?.targetObjectId == dotted ? draft : null);
    }
  }

  void _paintSelected(Canvas canvas, CanvasEdges edges) {
    final edge = edges.selected;
    final route = edge == null ? null : edges.routeOf(edge);
    if (route == null) return;
    final camera = document.camera;
    canvas
      ..save()
      ..scale(camera.zoom)
      ..translate(-camera.x, -camera.y)
      ..drawPath(
        route.path,
        Paint()
          ..color = outline.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = edgeLineWidth + 6 / camera.zoom
          ..strokeCap = StrokeCap.round,
      )
      ..restore();
    final radius = touchHandles ? 9.0 : 6.0;
    for (final at in [route.start, route.end]) {
      final centre = _screen(at);
      canvas
        ..drawCircle(centre, radius, Paint()..color = handleFill)
        ..drawCircle(
          centre,
          radius,
          Paint()
            ..color = handleBorder
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
    }
  }

  void _paintDots(Canvas canvas, Rect box, EdgeDraft? targeted) {
    final fill = Paint()..color = handleFill;
    final border = Paint()
      ..color = handleBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final hot = Paint()..color = outline;
    for (final entry in sideDots(box).entries) {
      final centre = _screen(entry.value);
      final active = targeted != null && targeted.targetSide == entry.key;
      canvas
        ..drawCircle(
            centre, active ? 7 : sideDotSizePx / 2, active ? hot : fill)
        ..drawCircle(centre, active ? 7 : sideDotSizePx / 2, border);
    }
  }

  void _paintDraft(Canvas canvas, CanvasEdges edges, EdgeDraft draft) {
    final spec = CanvasEdgeSpec(
      from: AttachedEnd(draft.fromObjectId, side: draft.fromSide),
      to: draft.targetObjectId == null
          ? FreeEnd(draft.pointer)
          : AttachedEnd(draft.targetObjectId!, side: draft.targetSide),
    );
    final route = routeEdge(
      spec,
      edges.boxOf(draft.fromObjectId),
      draft.targetObjectId == null ? null : edges.boxOf(draft.targetObjectId!),
    );
    if (route == null) return;
    final camera = document.camera;
    canvas
      ..save()
      ..scale(camera.zoom)
      ..translate(-camera.x, -camera.y)
      ..drawPath(
        route.path,
        Paint()
          ..color = outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = edgeLineWidth
          ..strokeCap = StrokeCap.round,
      )
      ..drawPath(
        Path()..addPolygon(route.endHead(EdgeArrow.end)!, true),
        Paint()..color = outline,
      )
      ..restore();
    if (draft.targetObjectId case final target?) {
      final box = edges.boxOf(target);
      if (box != null) {
        final c = document.camera;
        canvas.drawRect(
          Rect.fromLTWH(
            (box.left - c.x) * c.zoom,
            (box.top - c.y) * c.zoom,
            box.width * c.zoom,
            box.height * c.zoom,
          ),
          Paint()
            ..color = outline
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(EdgeOverlayPainter old) => !identical(old, this);
}
