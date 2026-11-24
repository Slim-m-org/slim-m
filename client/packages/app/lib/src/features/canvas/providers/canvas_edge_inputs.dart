// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Wire `edge` objects turned into what the document holds (decision 0137).
library;

import 'dart:ui' show Rect;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// The wire kind of a connection between objects.
const String canvasEdgeKind = 'edge';

/// What the document holds for [object], or null for an object that is not an edge or one this client cannot draw.
CanvasEdgeInput? canvasEdgeInputFrom(api.CanvasObject object) {
  if (object.kind != canvasEdgeKind) return null;
  final spec = CanvasEdgeSpec.fromProps(object.props);
  if (spec == null) return null;
  return CanvasEdgeInput(
    id: object.id,
    seq: object.seq,
    zIndex: object.zIndex,
    authorId: object.authorId,
    spec: spec,
    hull: Rect.fromLTWH(object.x, object.y, object.w, object.h),
  );
}

/// Applies [object] when it is an edge and returns true; false leaves it to the caller, which handles every other kind.
bool applyWireEdge(
  CanvasDocument document,
  api.CanvasObject object, {
  bool overwrite = false,
  int? snapshotSeq,
}) {
  if (object.kind != canvasEdgeKind) return false;
  if (canvasEdgeInputFrom(object) case final input?) {
    document.edges.applyPlaced(
      input,
      overwrite: overwrite,
      snapshotSeq: snapshotSeq,
    );
  }
  return true;
}
