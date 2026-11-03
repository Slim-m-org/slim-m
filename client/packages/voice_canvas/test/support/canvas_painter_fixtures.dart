// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared fixtures for the `StrokePainter` test files: a stub [Canvas] that
/// tracks the actual affine transform `save`/`translate`/`scale`/`restore`
/// build up, the way the real engine would, plus the small document
/// builders both files need.
///
/// Split out once `canvas_painters_test.dart` crossed the 500-line hard
/// limit, matching how the production code itself splits `canvas_painters
/// _shapes.dart` out of `canvas_painters.dart`: this file is the shared
/// half, `canvas_painters_test.dart` covers strokes and images, and
/// `canvas_painters_shapes_test.dart` covers notes and shapes.
library;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

const ink = Color(0xFFE86A5C);

class PainterTransform {
  const PainterTransform(this.tx, this.ty, this.scale);

  final double tx;
  final double ty;
  final double scale;

  Rect apply(Rect r) => Rect.fromLTRB(
        tx + scale * r.left,
        ty + scale * r.top,
        tx + scale * r.right,
        ty + scale * r.bottom,
      );
}

/// Records what each painter actually reaches at each draw call, not what
/// its constructor was handed: the device-space stroke width and bounds
/// after whatever `save`/`translate`/`scale` transform was active.
class RecordingCanvas implements Canvas {
  final List<double> deviceStrokeWidths = <double>[];
  final List<Rect> deviceBounds = <Rect>[];

  /// The colour of every pen-path draw, in call order.
  final List<Color> pathColors = <Color>[];
  final List<PainterTransform> _stack = <PainterTransform>[
    const PainterTransform(0, 0, 1),
  ];

  /// Every rounded-rect draw: an image placeholder's or a note's fill and
  /// its border, two calls per object and none for anything else this
  /// painter draws.
  int roundedRectCalls = 0;

  /// The corner radius of every rounded-rect draw, so a placeholder's and a
  /// note's own corner treatment can be compared against each other.
  final List<double> roundedRectRadii = <double>[];

  /// A shape's own draw calls, one kind of primitive at a time: a rectangle
  /// or an ellipse each draw once, a line draws once via [drawLine], and an
  /// arrow draws the same line plus two more via [drawLine] for its head.
  int rectCalls = 0;
  int ovalCalls = 0;
  int lineCalls = 0;

  /// Every plain-rect draw carrying a blur, which is what an elevation
  /// shadow's `Paint` looks like once `BoxShadow.toPaint()` builds it -
  /// nothing else this painter draws sets a `maskFilter` at all, so
  /// [drawRect] routes here instead of [rectCalls] whenever one is set.
  int shadowRectCalls = 0;

  /// The device-space stroke width of every shape draw (`drawRect`,
  /// `drawOval`, `drawLine`, excluding a shadow's own `drawRect`), so a
  /// shape's outline can be checked against the same zoom scaling a pen
  /// stroke's width already gets.
  final List<double> shapeStrokeWidths = <double>[];

  /// The device-space length of every `drawLine` segment, in call order: for
  /// an arrow this is the shaft followed by its two head wings.
  final List<double> lineDeviceLengths = <double>[];

  /// The device-space bounds of every `drawRect`/`drawOval` shape draw
  /// (excluding a shadow's own `drawRect`), so a shape's on-screen position
  /// and size can be checked unchanged by a stroke-width fix.
  final List<Rect> shapeDeviceBounds = <Rect>[];

  /// Every note body actually laid out and painted, so its real (already
  /// truncated, if truncation applied) height can be checked against the
  /// box that was supposed to bound it.
  final List<ui.Paragraph> paragraphs = <ui.Paragraph>[];

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    paragraphs.add(paragraph);
  }

  PainterTransform get _current => _stack.last;
  Offset _applyPoint(Offset p) => Offset(
        _current.tx + _current.scale * p.dx,
        _current.ty + _current.scale * p.dy,
      );

  @override
  void save() => _stack.add(_current);

  @override
  void restore() {
    if (_stack.length > 1) _stack.removeLast();
  }

  @override
  void translate(double dx, double dy) {
    final c = _current;
    _stack[_stack.length - 1] =
        PainterTransform(c.tx + c.scale * dx, c.ty + c.scale * dy, c.scale);
  }

  @override
  void scale(double sx, [double? sy]) {
    final c = _current;
    _stack[_stack.length - 1] = PainterTransform(c.tx, c.ty, c.scale * sx);
  }

  @override
  void drawPath(Path path, Paint paint) {
    deviceStrokeWidths.add(paint.strokeWidth * _current.scale);
    deviceBounds.add(_current.apply(path.getBounds()));
    pathColors.add(paint.color);
  }

  @override
  void drawRRect(RRect rrect, Paint paint) {
    roundedRectCalls++;
    roundedRectRadii.add(rrect.tlRadiusX);
  }

  @override
  void drawRect(Rect rect, Paint paint) {
    if (paint.maskFilter != null) {
      shadowRectCalls++;
      return;
    }
    rectCalls++;
    shapeStrokeWidths.add(paint.strokeWidth * _current.scale);
    shapeDeviceBounds.add(_current.apply(rect));
  }

  @override
  void drawOval(Rect rect, Paint paint) {
    ovalCalls++;
    shapeStrokeWidths.add(paint.strokeWidth * _current.scale);
    shapeDeviceBounds.add(_current.apply(rect));
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    lineCalls++;
    shapeStrokeWidths.add(paint.strokeWidth * _current.scale);
    lineDeviceLengths.add((_applyPoint(p2) - _applyPoint(p1)).distance);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

CanvasStrokeInput noteAt({String text = 'hello'}) => CanvasStrokeInput(
      id: 'note',
      seq: 1,
      zIndex: 1,
      x: 0,
      y: 0,
      w: 120,
      h: 80,
      points: const [],
      width: 0,
      colorKey: 'note',
      kind: CanvasObjectKind.note,
      text: text,
    );

CanvasStrokeInput shapeAt(CanvasShapeKind shapeKind) => CanvasStrokeInput(
      id: 'shape',
      seq: 1,
      zIndex: 1,
      x: 0,
      y: 0,
      w: 100,
      h: 60,
      points: const [],
      width: 0,
      colorKey: 'shape',
      kind: CanvasObjectKind.shape,
      shapeKind: shapeKind,
    );

/// A document holding one live image object with no bitmap yet, either
/// still waiting on a decode or one that failed for good.
CanvasDocument documentWithImage({required bool loadFailed}) {
  final document = CanvasDocument();
  document.setViewport(const Size(400, 400));
  document.applyPlaced(
    const CanvasStrokeInput(
      id: 'pic',
      seq: 1,
      zIndex: 1,
      x: 0,
      y: 0,
      w: 100,
      h: 100,
      points: [],
      width: 0,
      colorKey: '',
      kind: CanvasObjectKind.image,
      attachmentId: 'sha-pic',
    ),
  );
  if (loadFailed) document.markImageLoadFailed('pic');
  document.refresh();
  return document;
}

/// A document holding one committed horizontal stroke, camera set last so the
/// placed object is culled in before anything paints.
CanvasDocument documentWithCommittedStroke(
  double zoom, {
  String colorKey = 'ink',
}) {
  final document = CanvasDocument();
  document.setViewport(const Size(400, 400));
  document.applyPlaced(
    CanvasStrokeInput(
      id: 'committed',
      seq: 1,
      zIndex: 1,
      x: 0,
      y: 50,
      w: 100,
      h: 1,
      points: const [0, 0, 100, 0],
      width: 4,
      colorKey: colorKey,
    ),
  );
  document.setCamera(Camera(zoom: zoom));
  return document;
}

DraftStroke draftAlongTheSameLine() => DraftStroke()
  ..begin(const Offset(0, 175))
  ..extend(const Offset(350, 175));

/// `AppShadows.float`, copied verbatim - see `visual_tokens.dart`'s own
/// doc for why this package's tests hold a literal copy rather than a
/// dependency on the design system.
const elevationShadow = [
  BoxShadow(color: Color(0x85000000), blurRadius: 64, offset: Offset(0, 24)),
];
