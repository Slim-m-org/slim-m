// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Wire canvas objects turned into what the document paints.
library;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// Converts a wire object into what the document needs to paint a stroke or
/// an image, or null for a kind this client does not draw. Shared between a
/// viewport page, a live placement, and a `place` op read off the catch-up
/// feed, so the three paths cannot silently disagree on what counts as
/// paintable.
CanvasStrokeInput? canvasStrokeInputFrom(api.CanvasObject object) {
  return switch (object.kind) {
    'stroke' => _strokeInputFrom(object),
    'image' => _imageInputFrom(object),
    'note' => _noteInputFrom(object),
    'shape' => _shapeInputFrom(object),
    _ => null,
  };
}

/// Props are opaque to the server, so every field is checked with `is`: a
/// hard cast on a stored row that is wrong-typed would throw out of the
/// whole page or catch-up that carries it.
CanvasStrokeInput? _strokeInputFrom(api.CanvasObject object) {
  final raw = object.props['points'];
  if (raw is! List) return null;
  final width = object.props['width'];
  final color = object.props['color'];
  return CanvasStrokeInput(
    id: object.id,
    seq: object.seq,
    zIndex: object.zIndex,
    x: object.x,
    y: object.y,
    w: object.w,
    h: object.h,
    points: raw.whereType<num>().map((n) => n.toDouble()).toList(),
    width: width is num && width.isFinite && width > 0 ? width.toDouble() : 3,
    colorKey: color is String ? color : 'annotation',
    authorId: object.authorId,
  );
}

/// `props.attachment` is the one field this client actually reads; the rest
/// of an image's props (`content_type`, the natural pixel size) are only
/// ever written, not read back, since the box on the wire already says how
/// large to paint it.
CanvasStrokeInput? _imageInputFrom(api.CanvasObject object) {
  final attachment = object.props['attachment'];
  if (attachment is! String) return null;
  return CanvasStrokeInput(
    id: object.id,
    seq: object.seq,
    zIndex: object.zIndex,
    x: object.x,
    y: object.y,
    w: object.w,
    h: object.h,
    points: const [],
    width: 0,
    colorKey: '',
    authorId: object.authorId,
    kind: CanvasObjectKind.image,
    attachmentId: attachment,
  );
}

/// A note carries only its text; an edit op replaces it later.
CanvasStrokeInput? _noteInputFrom(api.CanvasObject object) {
  final text = object.props['text'];
  if (text is! String) return null;
  return CanvasStrokeInput(
    id: object.id,
    seq: object.seq,
    zIndex: object.zIndex,
    x: object.x,
    y: object.y,
    w: object.w,
    h: object.h,
    points: const [],
    width: 0,
    colorKey: 'note',
    authorId: object.authorId,
    kind: CanvasObjectKind.note,
    text: text,
  );
}

CanvasStrokeInput? _shapeInputFrom(api.CanvasObject object) {
  final shapeKind = canvasShapeKindFromWire(object.props['shape']);
  if (shapeKind == null) return null;
  return CanvasStrokeInput(
    id: object.id,
    seq: object.seq,
    zIndex: object.zIndex,
    x: object.x,
    y: object.y,
    w: object.w,
    h: object.h,
    points: const [],
    width: 0,
    colorKey: 'shape',
    authorId: object.authorId,
    kind: CanvasObjectKind.shape,
    shapeKind: shapeKind,
  );
}

/// The wire's `props.shape` string, or null for anything this client does
/// not recognise - the same "an unknown value paints nothing rather than
/// guessing" rule [canvasStrokeInputFrom] already applies to a whole kind.
CanvasShapeKind? canvasShapeKindFromWire(Object? raw) => switch (raw) {
  'rectangle' => CanvasShapeKind.rectangle,
  'ellipse' => CanvasShapeKind.ellipse,
  'line' => CanvasShapeKind.line,
  'arrow' => CanvasShapeKind.arrow,
  _ => null,
};

/// The reverse of [canvasShapeKindFromWire], for a placement request this
/// client sends.
String canvasShapeKindToWire(CanvasShapeKind kind) => switch (kind) {
  CanvasShapeKind.rectangle => 'rectangle',
  CanvasShapeKind.ellipse => 'ellipse',
  CanvasShapeKind.line => 'line',
  CanvasShapeKind.arrow => 'arrow',
};
