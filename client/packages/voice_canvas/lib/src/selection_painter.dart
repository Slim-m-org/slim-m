// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Painting the one object [CanvasDocument.selectedObjectId] names: an
/// outline in screen space, plus resize handles for every box-shaped kind
/// (image, note, shape).
///
/// A stroke can be selected too - `CanvasOpsController.beginSelect` falls
/// back to a path hit test once the tap misses every box kind (image, note,
/// shape) - but it never grows handles: a stroke has no thinner shape
/// inside its box for a corner drag to distort, and it is never draggable
/// either, only reorderable (bring to front, send to back). See
/// `canvas_pane_ops_test.dart`'s "move is scoped to box kinds" test for the
/// drag half of that split.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'canvas_document.dart';
import 'canvas_resize.dart';

/// Draws the current selection over the committed ink, one layer above
/// `StrokePainter` in `CanvasSurface`'s stack.
///
/// Handle size and hit radius are both fixed screen quantities (see
/// `canvas_resize.dart`), painted here with no `canvas.scale(zoom)` at all -
/// unlike `StrokePainter`, which paints ink in world scale. That is what
/// keeps a handle the same visual size at any zoom: usable up close without
/// ballooning, and still grabbable zoomed out rather than shrinking to a
/// point.
class SelectionPainter extends CustomPainter {
  SelectionPainter({
    required this.document,
    required this.outline,
    required this.handleFill,
    required this.handleBorder,
  }) : super(
            repaint: Listenable.merge([
          document,
          document.selectedObjectId,
          document.snapGuides,
        ]));

  final CanvasDocument document;
  final Color outline;
  final Color handleFill;
  final Color handleBorder;

  @override
  void paint(Canvas canvas, Size size) {
    _paintGuides(canvas);
    final id = document.selectedObjectId.value;
    if (id == null) return;
    final bounds = document.objectBounds(id);
    if (bounds == null) return;
    final camera = document.camera;

    final screen = Rect.fromLTWH(
      (bounds.x - camera.x) * camera.zoom,
      (bounds.y - camera.y) * camera.zoom,
      bounds.w * camera.zoom,
      bounds.h * camera.zoom,
    );
    final line = Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(screen, line);

    if (document.kindOf(id) == CanvasObjectKind.stroke) return;
    final fill = Paint()..color = handleFill;
    final border = Paint()
      ..color = handleBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final corner in resizeHandleCorners(bounds).values) {
      final at = Offset(
        (corner.dx - camera.x) * camera.zoom,
        (corner.dy - camera.y) * camera.zoom,
      );
      final handle = Rect.fromCenter(
        center: at,
        width: resizeHandleVisualSize,
        height: resizeHandleVisualSize,
      );
      canvas.drawRect(handle, fill);
      canvas.drawRect(handle, border);
    }
  }

  void _paintGuides(Canvas canvas) {
    final camera = document.camera;
    final paint = Paint()
      ..color = outline.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (final g in document.snapGuides.value) {
      final p =
          ((g.position - (g.vertical ? camera.x : camera.y)) * camera.zoom);
      final a = (g.start - (g.vertical ? camera.y : camera.x)) * camera.zoom;
      final b = (g.end - (g.vertical ? camera.y : camera.x)) * camera.zoom;
      canvas.drawLine(
        g.vertical ? Offset(p, a) : Offset(a, p),
        g.vertical ? Offset(p, b) : Offset(b, p),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(SelectionPainter oldDelegate) => false;
}
