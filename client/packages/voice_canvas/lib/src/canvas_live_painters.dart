// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas's ephemeral paint layers: this device's own in-progress
/// stroke, everyone else's in-flight strokes, and everyone's live pointers.
///
/// Split out of `canvas_painters.dart` once the elevation-shadow and
/// remote-draft work pushed it toward the 500-line hard limit a second time:
/// none of these four classes touches [StrokePainter]'s own private state,
/// so a plain sibling library is enough - unlike `canvas_painters_shapes.dart`,
/// which needs `part of` for exactly that access. Re-exported from
/// `canvas_painters.dart` so nothing importing that file has to change.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'canvas_cursors.dart';
import 'canvas_document.dart';
import 'canvas_painters.dart' show arrowheadLength, arrowheadWings;
import 'canvas_stroke_drafts.dart';
import 'cursor_label_cache.dart';

export 'cursor_label_contrast.dart' show cursorLabelColorFor;

/// The stroke currently under the pointer, in screen coordinates.
///
/// Its own layer and its own listenable so pointer-rate repaints never touch
/// the committed ink.
class DraftStroke extends ChangeNotifier {
  final List<Offset> _screenPoints = <Offset>[];

  List<Offset> get points => _screenPoints;
  bool get isEmpty => _screenPoints.isEmpty;

  void begin(Offset point) {
    _screenPoints
      ..clear()
      ..add(point);
    notifyListeners();
  }

  /// Adds a point unless it is within [minGap] device pixels of the last one,
  /// which is the simplification: measured in screen space, so it is
  /// zoom-aware for free.
  void extend(Offset point, {double minGap = 2}) {
    if (_screenPoints.isEmpty) {
      begin(point);
      return;
    }
    if ((point - _screenPoints.last).distance < minGap) return;
    _screenPoints.add(point);
    notifyListeners();
  }

  List<Offset> take() {
    final out = List<Offset>.from(_screenPoints);
    _screenPoints.clear();
    notifyListeners();
    return out;
  }

  void cancel() {
    if (_screenPoints.isEmpty) return;
    _screenPoints.clear();
    notifyListeners();
  }
}

/// Paints [DraftStroke] straight in screen space.
///
/// [width] is the pen's width in world units, the same quantity a committed
/// `CanvasStroke.width` carries, so it must be scaled by the live camera zoom
/// here or the preview disagrees with the committed-ink painter the moment
/// zoom is not 1.
class DraftPainter extends CustomPainter {
  DraftPainter({
    required this.draft,
    required this.document,
    required this.ink,
    required this.width,
  }) : super(repaint: Listenable.merge([draft, document]));

  final DraftStroke draft;
  final CanvasDocument document;
  final Color ink;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final points = draft.points;
    if (points.isEmpty) return;
    final paint = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = width * document.camera.zoom
      ..isAntiAlias = true;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    if (points.length == 1) path.lineTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(DraftPainter oldDelegate) =>
      oldDelegate.ink != ink || oldDelegate.width != width;
}

/// The box a shape tool is currently sizing by dragging, in screen
/// coordinates - [DraftStroke]'s own sibling for report 3 in the backlog
/// channel: "I don't see it until I let go of click". Screen space for the
/// same reason [DraftStroke] is: a drag is short enough that a mid-drag
/// camera change is not worth tracking.
class DraftShape extends ChangeNotifier {
  Offset? _anchor;
  Offset? _current;
  CanvasShapeKind _kind = CanvasShapeKind.rectangle;

  /// The box the drag has sized so far, or null before one has begun.
  Rect? get rect {
    final anchor = _anchor;
    final current = _current;
    return anchor == null || current == null
        ? null
        : Rect.fromPoints(anchor, current);
  }

  CanvasShapeKind get kind => _kind;

  void begin(Offset point, CanvasShapeKind kind) {
    _anchor = point;
    _current = point;
    _kind = kind;
    notifyListeners();
  }

  void update(Offset point) {
    if (_anchor == null) return;
    _current = point;
    notifyListeners();
  }

  /// The final box, or null if nothing was ever begun - clears the draft
  /// either way, the same one-shot shape [DraftStroke.take] already uses.
  Rect? take() {
    final result = rect;
    cancel();
    return result;
  }

  void cancel() {
    if (_anchor == null) return;
    _anchor = null;
    _current = null;
    notifyListeners();
  }
}

/// Paints [DraftShape] live, in screen space - [DraftPainter]'s own
/// treatment for a pen stroke, so a shape drag shows the box being sized
/// rather than only appearing once the pointer lifts. A fixed screen-space
/// stroke width, unlike the committed shape's world-scaled one: a
/// mid-drag preview does not need to track zoom exactly, only to exist. An
/// arrowhead is the exception, scaled by zoom so it does not change size when
/// the shape lands.
class DraftShapePainter extends CustomPainter {
  DraftShapePainter({
    required this.draft,
    required this.document,
    required this.color,
  }) : super(repaint: draft);

  final DraftShape draft;

  /// Read for the zoom only, so the head matches the committed arrow's.
  final CanvasDocument document;
  final Color color;

  static final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = draft.rect;
    if (rect == null || rect.width == 0 || rect.height == 0) return;
    final paint = _stroke..color = color;
    switch (draft.kind) {
      case CanvasShapeKind.ellipse:
        canvas.drawOval(rect, paint);
      case CanvasShapeKind.line:
        canvas.drawLine(rect.topLeft, rect.bottomRight, paint);
      case CanvasShapeKind.arrow:
        canvas.drawLine(rect.topLeft, rect.bottomRight, paint);
        _paintArrowhead(canvas, rect.topLeft, rect.bottomRight, paint);
      case CanvasShapeKind.rectangle:
        canvas.drawRect(rect, paint);
    }
  }

  void _paintArrowhead(Canvas canvas, Offset from, Offset to, Paint paint) {
    final (left, right) = arrowheadWings(
      from,
      to,
      headLength: arrowheadLength * document.camera.zoom,
    );
    canvas.drawLine(to, left, paint);
    canvas.drawLine(to, right, paint);
  }

  @override
  bool shouldRepaint(DraftShapePainter oldDelegate) => false;
}

/// Other participants' in-flight strokes, in world coordinates.
///
/// Its own layer and its own listening `repaint`, the same reasoning
/// [DraftPainter] already gives for keeping a drawer's own preview off the
/// committed-ink layer's repaint: a remote pointer moving mid-stroke must
/// not force the whole committed-ink layer to repaint, and vice versa.
/// Colours are drawn at 70% opacity - lighter than committed ink - so an
/// in-flight ghost never reads as though it has already landed.
class RemoteDraftPainter extends CustomPainter {
  RemoteDraftPainter({
    required this.drafts,
    required this.document,
    required this.colors,
  }) : super(repaint: Listenable.merge([drafts, document]));

  final RemoteStrokeDrafts drafts;
  final CanvasDocument document;

  /// The caller's own closed cursor-colour set, indexed by
  /// [CanvasStrokeDraft.colorIndex] - the same palette [CursorPainter]
  /// draws from, so a participant's in-flight ink and their cursor read as
  /// the same person.
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty) return;
    final camera = document.camera;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 3 * camera.zoom
      ..isAntiAlias = true;
    for (final draft in drafts.all) {
      final points = draft.points;
      if (points.length < 4) continue;
      paint.color =
          colors[draft.colorIndex % colors.length].withValues(alpha: 0.7);
      final path = Path()
        ..moveTo(
          (points[0] - camera.x) * camera.zoom,
          (points[1] - camera.y) * camera.zoom,
        );
      for (var i = 2; i < points.length; i += 2) {
        path.lineTo(
          (points[i] - camera.x) * camera.zoom,
          (points[i + 1] - camera.y) * camera.zoom,
        );
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(RemoteDraftPainter oldDelegate) => false;
}

/// Other participants' live pointers.
///
/// Its own layer, listening to both [cursors] and [document]: a cursor move
/// repaints with no camera change, and a pan repaints every shown cursor at
/// its new screen position with no cursor having moved in world space.
class CursorPainter extends CustomPainter {
  CursorPainter({
    required this.cursors,
    required this.document,
    required this.colors,
    this.labelFontFamily,
    this.glide = Duration.zero,
    this.now = DateTime.now,
    Listenable? glideTick,
  }) : super(
          repaint: Listenable.merge([
            cursors,
            document,
            if (glideTick != null) glideTick,
          ]),
        );

  final CanvasCursors cursors;
  final CanvasDocument document;

  /// How long a cursor glides to a newly-reported position. Zero (the
  /// default, and what a reduce-motion caller passes) draws each frame at
  /// its target exactly as before; anything longer needs [glideTick] wired
  /// to something that fires while a glide is in flight, since neither
  /// [cursors] nor [document] notifies between frames.
  final Duration glide;

  /// The clock a glide is read against, injectable for a test the same
  /// plain-value way [colors] and [labelFontFamily] already are - this
  /// package deliberately depends on Flutter alone, so no `clock` package.
  final DateTime Function() now;

  /// The caller's closed cursor-colour set, indexed by
  /// [CanvasCursor.colorIndex]. This package carries no palette of its own,
  /// the same convention every other painter here follows.
  final List<Color> colors;

  /// The app's own type family for the name chip, the same plain-value
  /// convention [colors] already follows: this package has no font of its
  /// own to fall back on, and leaving this null draws Flutter's platform
  /// default rather than the product's own IBM Plex Sans.
  final String? labelFontFamily;

  /// Pixels of screen-space margin past which a cursor is not worth drawing
  /// at all, since its glyph and label would be fully off-canvas anyway.
  static const double _cullMargin = 48;

  late final CursorLabelCache _labels = CursorLabelCache(
    fontFamily: labelFontFamily,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty) return;
    final camera = document.camera;
    final paintedAt = now();
    final all = cursors.all;
    for (final cursor in all) {
      final world = cursor.positionAt(paintedAt, glide);
      final at = Offset(
        (world.dx - camera.x) * camera.zoom,
        (world.dy - camera.y) * camera.zoom,
      );
      if (at.dx < -_cullMargin ||
          at.dy < -_cullMargin ||
          at.dx > size.width + _cullMargin ||
          at.dy > size.height + _cullMargin) {
        continue;
      }
      final color = colors[cursor.colorIndex % colors.length];
      _paintGlyph(canvas, at, color);
      _paintLabel(canvas, at, cursor.id, cursor.label, color);
    }
    // Reconcile every frame, since a size check misses a departed cursor whose slot an off-screen (uncached) one took.
    _labels.retain({for (final c in all) c.id});
  }

  /// Frees the label cache; a [CustomPainter] has no teardown hook of its own,
  /// so the owning surface calls this from its own `dispose`.
  void disposeLabels() => _labels.dispose();

  @visibleForTesting
  int get debugLabelCacheSize => _labels.size;

  /// A white rim behind the fill, not a second identical fill: the same path
  /// drawn twice with no stroke and no inset (the shape this replaces) paints
  /// the second pass directly over the first, so the white never actually
  /// shows - a cursor in a hue close to whatever sits behind it (another
  /// participant's ink, a similarly-toned object) had no contrast edge at all.
  ///
  /// The glyph is one path built once at the origin and translated into
  /// place, and the two paints are reused across cursors and frames: this
  /// runs per visible cursor on every repaint, which a drawer's cursor can
  /// trigger many times a second.
  void _paintGlyph(Canvas canvas, Offset at, Color color) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.drawPath(_glyphPath, _glyphRim);
    canvas.drawPath(_glyphPath, _glyphFill..color = color);
    canvas.restore();
  }

  static final Path _glyphPath = Path()
    ..moveTo(0, 0)
    ..lineTo(0, 15)
    ..lineTo(4.5, 11.5)
    ..lineTo(7, 17)
    ..lineTo(9.5, 16)
    ..lineTo(7, 10.5)
    ..lineTo(11.5, 10.5)
    ..close();
  static final Paint _glyphRim = Paint()
    ..color = const Color(0xFFFFFFFF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  static final Paint _glyphFill = Paint();

  void _paintLabel(
    Canvas canvas,
    Offset at,
    String id,
    String label,
    Color color,
  ) {
    if (label.isEmpty) return;
    final painter = _labels.painterFor(id, label, color);
    final origin = Offset(at.dx + 14, at.dy + 12);
    final chip = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        origin.dx - 4,
        origin.dy - 2,
        painter.width + 8,
        painter.height + 4,
      ),
      const Radius.circular(6),
    );
    canvas.drawRRect(chip, Paint()..color = color);
    painter.paint(canvas, origin);
  }

  @override
  bool shouldRepaint(CursorPainter oldDelegate) => false;
}
