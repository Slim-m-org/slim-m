// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How an edge is read aloud and named in the activity log: "Connection from X to Y".
library;

import 'package:slimm_voice_canvas/voice_canvas.dart';

/// A short name for what one end of an edge is attached to.
String edgeEndName(CanvasDocument document, EdgeEndSpec end) {
  switch (end) {
    case FreeEnd():
      return 'a point on the board';
    case AttachedEnd(:final objectId):
      final text = (document.textOf(objectId) ?? '').trim();
      final short = text.length > 40 ? '${text.substring(0, 40)}...' : text;
      return switch (document.kindOf(objectId)) {
        CanvasObjectKind.note => short.isEmpty ? 'a note' : 'note: $short',
        CanvasObjectKind.text => short.isEmpty ? 'a text box' : 'text: $short',
        CanvasObjectKind.image => 'an image',
        CanvasObjectKind.emoji => 'an emoji stamp',
        CanvasObjectKind.tile => 'a module tile',
        CanvasObjectKind.shape => 'a shape',
        _ => 'an object',
      };
  }
}

/// The accessibility label of the edge [id], with its label when it has one.
String edgeSemanticLabel(CanvasDocument document, String id) {
  final edge = document.edges.liveEdge(id);
  if (edge == null) return 'Connection';
  final from = edgeEndName(document, edge.spec.from);
  final to = edgeEndName(document, edge.spec.to);
  final label = edge.spec.label;
  return 'Connection from $from to $to${label == null ? '' : ': $label'}';
}
