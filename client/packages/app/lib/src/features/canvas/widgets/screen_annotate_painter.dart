// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Paints the strokes and circles viewers have drawn over a shared screen's tile.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../screen_overlay/providers/screen_annotation_board.dart';
import '../../screen_overlay/providers/screen_annotation_mapping.dart';
import '../providers/canvas_pen_style.dart';

/// Ink width on the tile, in logical pixels.
const screenMarkWidth = 3.0;

class ScreenMarksPainter extends CustomPainter {
  ScreenMarksPainter({
    required this.marks,
    required this.content,
    required this.now,
    super.repaint,
  });

  /// Read at paint time, so a repaint tick fades what is already drawn.
  final List<ScreenAnnotation> Function() marks;
  final Rect content;
  final DateTime Function() now;

  @override
  void paint(Canvas canvas, Size size) {
    final at = now();
    for (final mark in marks()) {
      final alpha = mark.alphaAt(at);
      if (alpha <= 0) continue;
      final ink =
          canvasPenInkByKey[mark.colorKey] ?? AppCanvasColors.annotation;
      final paint = Paint()
        ..color = ink.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = screenMarkWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      switch (mark.kind) {
        case ScreenAnnotationKind.stroke:
          _stroke(canvas, mark.points, paint);
        case ScreenAnnotationKind.shape:
          if (mark.points.length == 4) {
            final a = _at(mark.points[0], mark.points[1]);
            final b = _at(mark.points[2], mark.points[3]);
            canvas.drawOval(Rect.fromPoints(a, b), paint);
          }
        case ScreenAnnotationKind.note:
          break;
      }
    }
  }

  Offset _at(double x, double y) => fromNormalised(Offset(x, y), content);

  void _stroke(Canvas canvas, List<double> flat, Paint paint) {
    if (flat.length < 2) return;
    if (flat.length == 2) {
      canvas.drawCircle(
        _at(flat[0], flat[1]),
        screenMarkWidth / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }
    final path = Path()
      ..moveTo(_at(flat[0], flat[1]).dx, _at(flat[0], flat[1]).dy);
    for (var i = 2; i + 1 < flat.length; i += 2) {
      final p = _at(flat[i], flat[i + 1]);
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(ScreenMarksPainter old) =>
      old.content != content || old.marks != marks;
}

/// A sticky note on the tile, faded by the same clock as the ink.
class ScreenNoteChip extends StatelessWidget {
  const ScreenNoteChip({super.key, required this.text, required this.alpha});

  final String text;
  final double alpha;

  static const _ink = Color(0xFF1A1A1A);

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: alpha.clamp(0.0, 1.0),
    child: Container(
      constraints: const BoxConstraints(maxWidth: 200),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: AppCanvasColors.note,
        borderRadius: BorderRadius.circular(AppRadii.control),
        boxShadow: AppShadows.canvasTile,
      ),
      child: Text(text, style: AppText.caption.copyWith(color: _ink)),
    ),
  );
}
