// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Places one connection: shown at once under its final id, then settled by the server's reply.
///
/// A direct await like `CanvasQuickPlacement`, since a connection is a one-off. The server derives the stored box from the ends, so the box sent is only the hull this client already knows.
library;

import 'dart:ui' show Rect;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../ids.dart';
import '../providers/canvas_edge_inputs.dart';
import 'canvas_forbidden_message.dart';
import 'canvas_retry.dart';

class CanvasEdgePlacement {
  CanvasEdgePlacement({
    required this.client,
    required this.channelId,
    required this.document,
    required this.timedOutUntil,
    required this.authorId,
    required this.clearedSincePlacement,
  });

  final api.SlimmApi client;
  final String channelId;
  final CanvasDocument document;
  final int? Function() timedOutUntil;
  final String? Function() authorId;

  /// Whether a clear already applied here swept the object while its reply was in flight.
  final bool Function(api.CanvasObject object) clearedSincePlacement;

  bool _inFlight = false;

  /// Places [spec], or returns null after saying why it could not be.
  Future<api.CanvasObject?> place(
    CanvasEdgeSpec spec, {
    required void Function(String message) onError,
  }) async {
    if (_inFlight) return null;
    _inFlight = true;
    final id = newCanvasObjectId();
    final edges = document.edges;
    final shown = CanvasEdgeInput(
      id: id,
      seq: 0,
      zIndex: provisionalLocalZIndex,
      authorId: authorId(),
      spec: spec,
      hull: _hullOf(spec),
    );
    edges.applyPlaced(shown);
    try {
      final placed = await retryCanvasRequest(
        () => client.placeCanvasObject(
          channelId,
          id: id,
          kind: canvasEdgeKind,
          x: shown.hull.left,
          y: shown.hull.top,
          w: shown.hull.width,
          h: shown.hull.height,
          props: spec.toProps(),
        ),
      );
      if (clearedSincePlacement(placed)) {
        document
          ..removeObject(id)
          ..refresh();
      } else {
        applyWireEdge(document, placed);
      }
      return placed;
    } on api.ApiException catch (error) {
      edges.kill(id);
      onError(_explain(error, timedOutUntil()));
      return null;
    } finally {
      _inFlight = false;
    }
  }

  Rect _hullOf(CanvasEdgeSpec spec) {
    final parts = <Rect>[];
    for (final end in [spec.from, spec.to]) {
      switch (end) {
        case FreeEnd(:final point):
          parts.add(Rect.fromLTWH(point.dx, point.dy, 0, 0));
        case AttachedEnd(:final objectId):
          final box = document.edges.boxOf(objectId);
          if (box != null) parts.add(box);
      }
    }
    final hull = edgeHull(parts);
    return Rect.fromLTWH(hull.x, hull.y, hull.w, hull.h);
  }

  static String _explain(api.ApiException error, int? timedOutUntil) =>
      switch (error) {
        api.ForbiddenException() => canvasDrawForbiddenMessage(timedOutUntil),
        api.ConflictException(:final message)
            when message.contains('too many') =>
          'That object has too many connections.',
        api.ConflictException() => 'This canvas is full.',
        api.NotFoundException() => 'One of those objects is gone.',
        api.BadRequestException() => 'That connection was refused.',
        _ => 'That connection could not be placed.',
      };
}
